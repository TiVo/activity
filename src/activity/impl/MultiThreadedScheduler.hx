/** *************************************************************************
 * MultiThreadedScheduler.hx
 *
 * Copyright 2014 TiVo, Inc.
 ************************************************************************** **/

package activity.impl;

import activity.Activity;
import sys.net.Socket;
import sys.net.SocketSelector;
#if cpp
import cpp.vm.Deque;
import cpp.vm.Mutex;
import cpp.vm.Thread;
import cpp.vm.Tls;
#elseif neko
import neko.vm.Deque;
import neko.vm.Mutex;
import neko.vm.Thread;
import neko.vm.Tls;
#elseif java
import java.vm.Deque;
import java.vm.Mutex;
import java.vm.Thread;
import java.vm.Tls;
#else
#error MultiThreadedScheduler has not been ported to this platform!
#end


class MultiThreadedScheduler
{
    public static function getCurrentActivity() : Activity
    {
        return gCurrentActivityTls.value;
    }

    public static function create(uncaught : Dynamic -> Void,
                                  name : String) : Activity
    {
        return new ActivityImpl(uncaught, name);
    }

    public static function run(completion : Void -> Void)
    {
        // These arrays are re-used every time a select over a set of sockets
        // is required, so as not to have to create new arrays every time,
        // thus reducing churn
        var readableArray = new Array<Socket>();
        var writableArray = new Array<Socket>();

        gMutex.acquire();
        gRunning = true;
        // Before run() was called, any activities scheduled on gRunnable
        // would not have had a thread created to run them (since the
        // scheduling functions do not start a thread if gRunning is not
        // true).  So start up a thread as necessary now that running is
        // really happening.
        createThreadIfNecessaryLocked();

        while (true) {
            // Collect readable Sockets (if any), writable Sockets (if any),
            // and timeout (if any).
            var readable : Array<Socket>;
            var writable : Array<Socket>;

            for (state in gReadableSockets) {
                if (!state.pending) {
                    readableArray.push(state.socket);
                }
            }
            readable = (readableArray.length == 0) ? null : readableArray;

            for (state in gWritableSockets) {
                if (!state.pending) {
                    writableArray.push(state.socket);
                }
            }
            writable = (writableArray.length == 0) ? null : writableArray;

            var timeout : Null<Float>;

            if (gFuture.length == 0) {
                timeout = null;
                gWakeupTime = -1;
            }
            else {
                gWakeupTime = gFuture.head.future.head.when;
                timeout = gWakeupTime - now();
                if (timeout < 0) {
                    timeout = 0;
                }
            }

            // If there are no readable sockets, no writable sockets, no
            // timers, and everything previously scheduled has already run ...
            if ((readable == null) && (writable == null) &&
                (timeout == null) && (gScheduledCount == 0)) {
                // ... then, nothing can happen anymore, so finish the run
                // loop.  Push a null into gRunnable for each runner thread,
                // which will cause all runner threads to exit.
                var i = 0;
                while (i < gThreadCount) {
                    gRunnable.push(null);
                    i += 1;
                }
                break;
            }

            // Do the select
            gMutex.release();
            gSelector.select(readable, writable, null, timeout);
            gMutex.acquire();

            // Set gWakeupTime to null so that the logic in the timer()
            // function that would try to wake up poll does not do so
            gWakeupTime = null;

            // Handle timers
            if (gFuture.head != null) {
                var currentTime = now();
                while ((gFuture.head != null) &&
                       (gFuture.head.future.head.when <= currentTime)) {
                    makeRunnableLocked(gFuture.popHead());
                }
            }

            // For each writable socket, push a ScheduledSocket onto the
            // "writable" list, then do the same for readable sockets and the
            // "readable" list.  Writable callbacks are scheduled before
            // socket readable callbacks just in case the write operation that
            // may occur in the callback prompts more data to be available in
            // the read.
            if (writable != null) {
                var i = 0;
                while (i < writable.length) {
                    var sock = writable[i++];
                    var state = gWritableSockets.get(sock);
                    if ((state != null) && !state.pending) {
                        state.pending = true;
                        if (state.writeScheduled == null) {
                            state.writeScheduled = new ScheduledSocket(sock);
                        }
                        state.activity.writable.pushAfterTail
                            (state.writeScheduled);
                        makeRunnableLocked(state.activity);
                    }
                }
                writable.splice(0, writable.length);
            }
            if (readable != null) {
                var i = 0;
                while (i < readable.length) {
                    var sock = readable[i++];
                    var state = gReadableSockets.get(sock);
                    if ((state != null) && !state.pending) {
                        state.pending = true;
                        if (state.readScheduled == null) {
                            state.readScheduled = new ScheduledSocket(sock);
                        }
                        state.activity.readable.pushAfterTail
                            (state.readScheduled);
                        makeRunnableLocked(state.activity);
                    }
                }
                readable.splice(0, readable.length);
            }
        }

        // Wait for all threads to exit
        while (gThreadCount > 0) {
            gMutex.release();
            gShutdownDeque.pop(true);
            gMutex.acquire();
        }

        // Drain the remainder of the notifications out of the shutdown deque
        while (gShutdownDeque.pop(false) != null) {
        }

        gRunning = false;
        gMutex.release();

        if (completion != null) {
            completion();
        }
    }

    public static function immediately(f : Void -> Void,
                                       cancellable : Bool) : CancelId
    {
        var current : ActivityImpl = cast getCurrentActivity();
#if AUDIT_ACTIVITY
        if (current == null) {
            throw "Must call Scheduler.immediately() from within an Activity";
        }
#end
        if (current.shutdown) {
            throw ActivityError.Shutdown;
        }
        // No need to lock while pushing onto the immediate queue as only the
        // calling Activity can ever manipulate it.
        var s = Scheduled.acquire_callme(current, cancellable, f, null);
        current.immediate.pushAfterTail(s);
        // The activity is now runnable, push it onto the runnable queue if
        // it's not already there.
        makeRunnable(current);
        return s.cancelId;
    }

    public static function soon(act : Activity, f : Void -> Void,
                                onShutdown : Void -> Void,
                                cancellable : Bool) : CancelId
    {
        var activityImpl : ActivityImpl = cast act;
        // If onShutdown is not null, schedule a closure that schedules it
        // onto the calling Activity when the target activity actually shuts
        // down, catching and ignoring a shutdown error if the calling
        // activity itself has already shut down.
        var s = Scheduled.acquire_callme
            (activityImpl, cancellable, f,
             (onShutdown == null) ? null :
             function ()
             {
                 try {
                     soon(getCurrentActivity(), f, null, false);
                 }
                 catch (e : activity.ActivityError) {
                     // Ignore shutdown error here
                 }
             });
        // Need to hold the lock while pushing the Schedule object onto the
        // activity's normal queue, since more than one activity can push onto
        // the normal queue of an activity at a time.
        gMutex.acquire();
        if (activityImpl.shutdown) {
            gMutex.release();
            Scheduled.release(s);
            throw ActivityError.Shutdown;
        }
        activityImpl.soon.pushAfterTail(s);
        makeRunnableLocked(activityImpl);
        gMutex.release();
        return s.cancelId;
    }

    public static function later(f : Void -> Void,
                                 cancellable : Bool) : CancelId
    {
        var current : ActivityImpl = cast getCurrentActivity();
#if AUDIT_ACTIVITY
        if (current == null) {
            throw "Must call Scheduler.later() from within an Activity";
        }
#end
        if (current.shutdown) {
            throw ActivityError.Shutdown;
        }
        var s = Scheduled.acquire_callme(current, cancellable, f, null);
        // No need to lock while pushing onto the immediate queue as only the
        // calling Activity can ever manipulate it.
        current.later.pushAfterTail(s);
        // The activity is now runnable, push it onto the runnable queue if
        // it's not already there.
        makeRunnable(current);
        return s.cancelId;
    }

    public static function timer(f : Float -> Void, timeout : Float,
                                 cancellable : Bool) : CancelId
    {
        var current : ActivityImpl = cast getCurrentActivity();
#if AUDIT_ACTIVITY
        if (current == null) {
            throw "Must call Scheduler.timer() from within an Activity";
        }
#end
        if (current.shutdown) {
            throw ActivityError.Shutdown;
        }

        if (timeout < 0) {
            timeout = 0;
        }

        var s : Scheduled = Scheduled.acquire_timer
            (current, cancellable, f, now() + timeout);
        gMutex.acquire();
        // If the timeout is 0 or less, then the timer is already expired; no
        // reason to put it into the "future" queue, just put it immediately
        // at the end of the "already expired timer" queue.
        if (timeout <= 0) {
            // No need to acquire the lock since only the activity itself
            // could call timer().
            current.expired.pushAfterTail(s);
            makeRunnableLocked(current);
        }
        else {
            // If it's the first timer, push it onto the tail of the empty
            // future list
            if (current.future.head == null) {
                current.future.pushAfterTail(s);
            }
            // Else, find the timer that it should be inserted before, and
            // insert before it
            else {
                var before = current.future.head.next;
                while ((before != current.future.head) &&
                       (s.when >= before.when)) {
                    before = before.next;
                }
                current.future.insertBefore(before, s);
            }
            // If the activity is already on the gFuture list, then possibly
            // re-order it within that list
            if (current.next != null) {
                // Find the one that it should go before
                var before = gFuture.head;
                do {
                    if (before.future.head.when > s.when) {
                        break;
                    }
                } while ((before = before.next) != gFuture.head);
                // If it's not where it needs to be already, move it
                if ((before != current) && (before.prev != current)) {
                    gFuture.remove(current);
                    gFuture.insertBefore(before, current);
                }
            }
            else {
                addToFutureList(current, s.when);
            }

            if ((gWakeupTime != null) && 
                ((gWakeupTime < 0) || (s.when < gWakeupTime))) {
                // Ensure that the select wakes up and handles this timer
                gSelector.cancel();
            }
        }
        gMutex.release();
        return s.cancelId;
    }

    public static function cancel(cancelId : CancelId)
    {
        Scheduled.cancel(cancelId);
    }

    public static function shutdown()
    {
        var current : ActivityImpl = cast getCurrentActivity();

        if (current == null) {
#if AUDIT_ACTIVITY
            throw "Must call Activity.shutdown() from within an Activity";
#else
            return;
#end
        }
        shutdownActivity(current);
    }

    public static function choose(activities : Iterator<Activity>) : Activity
    {
        gMutex.acquire();

        var bestScore : Float = -1;
        var bestActivity : Activity = null;

        for (activity in activities) {
            // If the Activity appears more than once in the array and has
            // already been determined to be the best, no need to re-evaluate
            // it.
            if (activity == bestActivity) {
                continue;
            }
            // Get the score for this Activity
            var score = cast(activity, ActivityImpl).getScore();
            // If score < 0, then this activity is not scheduled at all and
            // can be immediately returned.
            if (score < 0) {
                gMutex.release();
                return activity;
            }
            // Else, if this activity has a better score than the best
            // activity thus far, use it
            if (score > bestScore) {
                bestScore = score;
                bestActivity = activity;
            }
        }

        gMutex.release();

        return bestActivity;
    }
    
    public static function setSocketPollInterval(seconds : Float)
    {
        if (seconds < 0) {
            seconds = 0;
        }
        gSocketPollInterval = seconds;
    }

    public static function socketReadable(f : Void -> Void, socket : Socket)
    {
        var current : ActivityImpl = cast getCurrentActivity();
#if AUDIT_ACTIVITY
        if (current == null) {
            throw ("Must call Scheduler.socketReadable() from within a " +
                   "Activity");
        }
#end

        socketAble(gReadableSockets, socket, current, f);
    }

    public static function socketWritable(f : Void -> Void, socket : Socket)
    {
        var current : ActivityImpl = cast getCurrentActivity();
#if AUDIT_ACTIVITY
        if (current == null) {
            throw ("Must call Scheduler.socketWritable() from within a " +
                   "Activity");
        }
#end

        socketAble(gWritableSockets, socket, current, f);
    }

    private static function shutdownActivity(activity : ActivityImpl)
    {
        gMutex.acquire();

        shutdownActivityLocked(activity);

        gMutex.release();
    }

    private static function shutdownActivityLocked(activity : ActivityImpl)
    {
        // Mark it and all of its children as shut down
        if (activity.shutdown) {
            // Already shut down ...
            return;
        }

        // Eliminate all socket listens for it
        var socketMapChanged = false;
        var toRemove : Array<Socket> = [ ];
        for (socket in gReadableSockets.keys()) {
            if (gReadableSockets.get(socket).activity == activity) {
                toRemove.push(socket);
            }
        }
        if (toRemove.length > 0) {
            socketMapChanged = true;
            var i = 0;
            while (i < toRemove.length) {
                gReadableSockets.remove(toRemove[i++]);
            }            
        }
        toRemove = [ ];
        for (socket in gWritableSockets.keys()) {
            if (gWritableSockets.get(socket).activity == activity) {
                toRemove.push(socket);
            }
        }
        if (toRemove.length > 0) {
            socketMapChanged = true;
            var i = 0;
            while (i < toRemove.length) {
                gWritableSockets.remove(toRemove[i++]);
            }            
        }
        if (socketMapChanged) {
            gSelector.cancel();
        }

        // Remove it from its parent
        if (activity.parent != null) {
            activity.parent.children.remove(activity);
        }

        // Shut down its children
        while (activity.children.length > 0) {
            shutdownActivityLocked(activity.children[0]);
        }

        activity.shutdown = true;
    }

    private static function makeRunnable(activity : ActivityImpl)
    {
        // Hold the mutex which protects gRunnable and the runnable field of
        // all Activities, to prevent simultaneous access between the main
        // thread doing timer activations, and activity runner threads.
        gMutex.acquire();
        makeRunnableLocked(activity);
        gMutex.release();
    }

    private static inline function makeRunnableLocked(activity : ActivityImpl)
    {
        // Only if it's not already on the list (i.e. only if its next is null)
        if (!activity.runnable) {
            activity.runnable = true;
            gRunnable.push(activity);
            gScheduledCount += 1;
            // Now create a thread to run it if necessary
            createThreadIfNecessaryLocked();
        }
    }

    private static function addToFutureList(activity : ActivityImpl,
                                            when : Float)
    {
        if (gFuture.head == null) {
            gFuture.pushAfterTail(activity);
        }
        else {
            var before = gFuture.head.next;
            while ((before != gFuture.head) &&
                   (when >= before.future.head.when)) {
                before = before.next;
            }
            gFuture.insertBefore(before, activity);
        }
    }

    // Helper function that adds a socket to the readable/writable set
    private static function socketAble(m : SocketMap, socket : Socket,
                                       a : ActivityImpl, f : Void -> Void)
    {
        if (a.shutdown) {
            throw ActivityError.Shutdown;
        }

        gMutex.acquire();

        if (f == null) {
            if (m.exists(socket)) {
                m.remove(socket);
                gSelector.cancel();
            }
        }
        else {
            var state = m.get(socket);
            if (state == null) {
                state = new SocketState(socket);
                m.set(socket, state);
                gSelector.cancel();
            }
            state.activity = a;
            state.func = f;
        }

        gMutex.release();
    }

    private static function createThreadIfNecessaryLocked()
    {
        // Do not create any threads if not running yet
        if (!gRunning) {
            return;
        }

        // Limit activity runner thread count to MAX_ACTIVITY_THREADS, or
        // 16 if MAX_ACTIVITY_THREADS is not defined
        if (gThreadCount >=
            #if MAX_ACTIVITY_THREADS MAX_ACTIVITY_THREADS #else 16 #end) {
            return;
        }

        // If no threads are waiting to run an activity, start a thread.
        if (gWaitingCount == 0) {
            gThreadCount += 1;
            Thread.create(threadFunction);
        }
    }

    private static function threadFunction()
    {
        gMutex.acquire();
        while (true) {
            gWaitingCount += 1;
            // If the scheduled count is now 0, and the main thread is waiting
            // forever, wake it up, because it's possible that it's time for
            // it to exit
            if ((gScheduledCount == 0) && (gWakeupTime == -1)) {
                gSelector.cancel();
            }
            gMutex.release();

            var activity = gRunnable.pop(true);

            gMutex.acquire();
            gWaitingCount -= 1;

            if (activity == null) {
                // This means shut down
                gScheduledCount -= 1;
                break;
            }

            gMutex.release();
            // Run immediate calls for this activity
            runActivity(activity);
            gMutex.acquire();

            gScheduledCount -= 1;
        }

        gThreadCount -= 1;
        gMutex.release();

        gShutdownDeque.push(true);
    }

    private static function runActivity(activity : ActivityImpl)
    {
        if (activity.shutdown) {
            return;
        }

        gCurrentActivityTls.value = activity;
        
        while (!activity.shutdown) {
            // Run immediate call
            var s = activity.immediate.popHead();
            if (s != null) {
                runScheduled(s);
                continue;
            }

            // Move all expired timers to the expired list
            gMutex.acquire();
            var currentTime = now();
            while ((activity.future.head != null) &&
                   (activity.future.head.when <= currentTime)) {
                activity.expired.pushAfterTail(activity.future.popHead());
            }

            // If the activity is still on the gFuture list, remove it,
            // because it has no more future timers
            if ((activity.future.head == null) && (activity.next != null)) {
                gFuture.remove(activity);
            }

            // Now that the global lock is held, use this opportunity to
            // atomically check for this activity having nothing more to run
            if ((activity.immediate.head == null) &&
                (activity.expired.head == null) &&
                (activity.writable.head == null) &&
                (activity.readable.head == null) &&
                (activity.soon.head == null) &&
                (activity.later.head == null)) {
                // If the activity still has timers that will eventually
                // expire, and the activity is not on the gFuture list, add it
                // so that the main loop will manage its timers
                if ((activity.next == null) && (activity.future.head != null)) {
                    addToFutureList(activity, activity.future.head.when);
                }
                activity.runnable = false;
                gMutex.release();
                break;
            }

            // Run an expired timer if there is one
            var s = activity.expired.popHead();
            if (s != null) {
                gMutex.release();
                runScheduled(s);
                continue;
            }

            // Run writable socket if there is one.  Need the lock for
            // accessing activity.soon since it can be pushed to by other
            // threads.
            var sch = activity.writable.popHead();
            var ran = false;
            while (sch != null) {
                var state = gWritableSockets.get(sch.socket);
                // If state is null or activity is not the same, this activity
                // is not listening for writable on this socket anymore.
                if ((state != null) && state.pending &&
                    (state.activity == activity)) {
                    // Run it
                    state.pending = false;
                    var f = state.func;
                    gMutex.release();
                    try {
                        f();
                    }
                    catch (thrown : Dynamic) {
                        if (state.activity.uncaught != null) {
                            state.activity.uncaught(thrown);
                        }
                        else {
                            shutdownActivity(state.activity);
                        }
                    }
                    ran = true;
                    break;
                }
                sch = activity.writable.popHead();
            }
            if (ran) {
                continue;
            }

            sch = activity.readable.popHead();
            ran = false;
            while (sch != null) {
                var state = gReadableSockets.get(sch.socket);
                // If state is null or activity is not the same, this activity
                // is not listening for readable on this socket anymore.
                if ((state != null) && state.pending &&
                    (state.activity == activity)) {
                    // Run it
                    state.pending = false;
                    var f = state.func;
                    gMutex.release();
                    try {
                        f();
                    }
                    catch (thrown : Dynamic) {
                        if (state.activity.uncaught != null) {
                            state.activity.uncaught(thrown);
                        }
                        else {
                            shutdownActivity(state.activity);
                        }
                    }
                    ran = true;
                    break;
                }
                sch = activity.readable.popHead();
            }
            if (ran) {
                continue;
            }

            // Run soon call if there is one.  Need the lock for accessing
            // activity.soon since it can be pushed to by other threads.
            var s = activity.soon.popHead();
            gMutex.release();
            if (s != null) {
                runScheduled(s);
                continue;
            }

            // Run later call if there is one
            s = activity.later.popHead();
            if (s != null) {
                runScheduled(s);
                continue;
            }
        }

        gCurrentActivityTls.value = null;
    }

    private static inline function runScheduled(s : Scheduled)
    {
        // Run the callback in a try block that catches exceptions and feeds
        // them to the "uncaught" function of the activity if there is one
        var thrown : Dynamic = null;
        try {
            s.run();
        }
        // On any exception, store the caught exception in the thrown variable
        catch (e : Dynamic) {
            thrown = e;
        }
        // Put the scheduled call back into the pool so that it can be
        // re-used.  Note that this cannot be done before the call is made,
        // because putting it back into the pool clears out fields that may
        // have been needed to make the call.
        Scheduled.release(s);
        // Audit that no mutex locks were held when the call returned.  This
        // is done before passing any thrown exception on, to ensure that when
        // activities throw errors out of their calls, that they always unlock
        // mutexes before doing so, which would be a common error and should
        // be reported.
        var current : ActivityImpl = cast getCurrentActivity();
#if AUDIT_ACTIVITY
        if (activity.Mutex.activityHasLockedMutex(current)) {
            throw MutexStillLocked;
        }
#end
        // If an exception was thrown from the scheduled function call ...
        if (thrown != null) {
            // If the current activity declared a "caught" function to be
            // called when an exception occurs, call it.  If it throws an
            // exception, then the exception doesn't get caught and ends up
            // throwing all the way out of the thread's main
            if (current.uncaught != null) {
                current.uncaught(thrown);
            }
            // Else, there is no exception handler for this activity, so shut
            // down the activity
            else {
                shutdownActivity(current);
            }
        }
    }

    private static inline function now() : Float
    {
        return haxe.Timer.stamp();
    }

    // Each thread in the scheduler thread pool has a Tls structure to hold
    // thread global data pertaining to activities
    private static var gCurrentActivityTls : Tls<ActivityImpl> =
        new Tls<ActivityImpl>();
    // Set to true only when the scheduler thread is running within run().
    // Activity runner threads are only created when the scheduler thread
    // is in run().
    private static var gRunning : Bool = false;
    // Number of activity runner threads
    private static var gThreadCount : Int;
    // Number of activity runner threads waiting for an activity to run
    private static var gWaitingCount : Int;
    // Each activity runner thread notifies its exit via a push to this
    // Deque.  This allows the scheduler main thread to wait for all activity
    // runners to complete before exiting run().
    private static var gShutdownDeque : Deque<Null<Bool>> =
        new Deque<Null<Bool>>();
    // This is the set of Activities with currently runnable callbacks.
    // Threads from the scheduler thread pool pull from this list.
    private static var gRunnable : Deque<Null<ActivityImpl>> =
        new Deque<Null<ActivityImpl>>();
    // Total number of calls scheduled that have not been run yet
    private static var gScheduledCount : Int;
    // This is the list of ActivityImpl instances which have timers scheduled,
    // ordered by the nearest expiration of each ActivityImpl
    private static var gFuture : FastList<ActivityImpl> =
        new FastList<ActivityImpl>();
    // This is the time that the main thread will wake up from its current
    // poll() call.  It is null when the main thread is not in poll, and < 0
    // when the main thread is waiting forever in poll.
    private static var gWakeupTime : Null<Float>;
    // Boolean indicating whether or not there are any sockets at all.  Used
    // to short circuit unnecessary calls into select().
    private static var gHasSockets : Bool = false;
    private static var gSocketPollInterval : Float = 0.1; // 1/10 s = 100 ms
    // The set of sockets
    private static var gReadableSockets : SocketMap = new SocketMap();
    private static var gWritableSockets : SocketMap = new SocketMap();
    private static var gSelector : SocketSelector = new SocketSelector();
    // This mutex protects all of the above from simultaneous access by
    // multiple scheduler thread pool threads
    private static var gMutex : Mutex = new Mutex();
}


private typedef ScheduledList = FastList<Scheduled>;
private typedef SocketMap = haxe.ds.ObjectMap<Socket, SocketState>;


private class ActivityImpl extends Activity
{
    // Parent, may be null
    public var parent : Null<ActivityImpl>;
    // Children
    public var children : Array<ActivityImpl>;
    // True only when this ActivityImpl is on the runnable list or is running
    public var runnable : Bool;
    // True when this ActivityImpl has been shut down
    public var shutdown : Bool;
    // Immediate callme queue
    public var immediate : FastList<Scheduled>;
    // Writable socket queue
    public var writable : FastList<ScheduledSocket>;
    // Readable socket queue
    public var readable : FastList<ScheduledSocket>;
    // Soon callme queue
    public var soon : FastList<Scheduled>;
    // Later callme queue
    public var later : FastList<Scheduled>;
    // Expired timer queue
    public var expired : FastList<Scheduled>;
    // Pending timer queuen
    public var future : FastList<Scheduled>;
    // If non-null, called when an uncaught exception occurs on this Activity
    public var uncaught : Dynamic -> Void;
    // Puts the ActivityImpl on the scheduler's gFuture list when it has a
    // pending timer
    public var prev : Null<ActivityImpl>;
    public var next : Null<ActivityImpl>;
    // Lock protecting some of the above
    public var mutex : Mutex;

    public function new(uncaught : Dynamic -> Void, name : String)
    {
        super(name);
        
        this.parent = cast(MultiThreadedScheduler.getCurrentActivity(), 
                           ActivityImpl);
        this.children = [ ];
        this.runnable = false;
        this.shutdown = false;
        this.immediate = new FastList<Scheduled>();
        this.writable = new FastList<ScheduledSocket>();
        this.readable = new FastList<ScheduledSocket>();
        this.soon = new FastList<Scheduled>();
        this.later = new FastList<Scheduled>();
        this.future = new FastList<Scheduled>();
        this.expired = new FastList<Scheduled>();
        this.future = new FastList<Scheduled>();
        this.uncaught = uncaught;
        this.prev = null;
        this.next = null;
        this.mutex = new Mutex();
    }

    public inline function lock()
    {
        this.mutex.acquire();
    }

    public inline function unlock()
    {
        this.mutex.release();
    }

    // Returns a score for use in choosing which Activity to return from
    // Scheduler.choose()
    public function getScore() : Float
    {
        // If it's currently running, give it a score of 0 since it's
        // currently executing a call
        if (this.runnable) {
            return 0;
        }

        // Score of 0 if there is work already scheduled to be done
        if ((this.immediate.length > 0) || (this.soon.length > 0)) {
            return 0;
        }

        // If there are no future timers, then score -1
        if (this.future.head == null) {
            return -1;
        }

        // Return the nearest timeout
        return this.future.head.when;
    }
}


// State for handling the readable or writable call for a Socket.
private class ScheduledSocket
{
    public var socket(default, null) : Socket;

    // The prev and next references put the ScheduledSocket object on up to
    // one FastList
    public var prev : Null<ScheduledSocket>;
    public var next : Null<ScheduledSocket>;

    public function new(socket : Socket)
    {
        this.socket = socket;
    }
}

private class SocketState
{
    public var socket : Socket;
    public var activity : ActivityImpl;
    public var func : Void -> Void;
    public var pending : Bool;

    public var readScheduled : ScheduledSocket;
    public var writeScheduled : ScheduledSocket;

    public function new(socket : Socket)
    {
        this.socket = socket;
        this.activity = null;
        this.func = null;
        this.pending = false;
        this.readScheduled = null;
        this.writeScheduled = null;
    }
}
