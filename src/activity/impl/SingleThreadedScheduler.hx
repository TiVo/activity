/** *************************************************************************
 * SingleThreadedScheduler.hx
 *
 * Copyright 2014 TiVo, Inc.
 ************************************************************************** **/

package activity.impl;

import activity.Activity;
import activity.Mutex;
import sys.net.Socket;

/**
 * This class implements the Scheduler on single threaded platforms that
 * control the main loop.  The Scheduler is used by the Activity API to
 * actually accomplish the work of scheduling and running Activity callbacks.
 **/
class SingleThreadedScheduler
{
    /**
     * Because this is a single threaded implementation, the current activity
     * is kept in a global variable that doesn't require any locking.  There
     * is only one thread at a time that could possibly access this global.
     **/
    public static inline function getCurrentActivity() : Activity
    {
        return gCurrentActivity;
    }

    /**
     * This implementation uses ActivityImpl, a subclass of Activity that
     * stores state associated with activities in a single threaded
     * environment.  ActivityImpl is defined near the end of this file.
     **/   
    public static function create(uncaught : Dynamic -> Void,
                                  name : String) : Activity
    {
        return new ActivityImpl(uncaught, name);
    }

    /**
     * Run loop on single threaded platforms just runs all outstanding
     * activity callbacks to completion, and sleeps on Sockets/timers when
     * there is no scheduled callback to be made.  Exits when there is nothing
     * left for any activity to possibly do.
     **/
    public static function run(completion : Void -> Void)
    {
        while (true) {
            // Run immediate calls
            while (true) {
                var s = gImmediate.popHead();
                if (s == null) {
                    break;
                }
                (cast(s.activity, ActivityImpl)).immediateCount -= 1;
                runScheduled(s);
            }

            // If there are sockets to poll and the poll interval has elapsed,
            // then run a zero timeout select to poll Socket events
            if (gHasSockets && 
                ((gMostRecentSelect + gSocketPollInterval) <= now())) {
                doSelect(0);
            }
            
            // Move expired timers from future list to expired list
            expireTimers();

            // Run an expired timer if there is one
            var s = gExpired.popHead();
            if (s != null) {
                (cast(s.activity, ActivityImpl)).normalCount -= 1;
                runScheduled(s);
                continue;
            }

            // Run normal call if there is one
            s = gNormal.popHead();
            if (s != null) {
                (cast(s.activity, ActivityImpl)).normalCount -= 1;
                runScheduled(s);
                continue;
            }

            // Run later call if there is one
            s = gLater.popHead();
            if (s != null) {
                runScheduled(s);
                continue;
            }

            // If there are timeouts scheduled, then select until the first
            // timeout expiration
            if (gFuture.head != null) {
                var timeout = gFuture.head.when - now();
                if (timeout > 0) {
                    doSelect(timeout);
                }
                continue;
            }

            // There is no timeout, but if there are readable and/or writable
            // sockets then run an indefinite select
            if (gHasSockets) {
                doSelect(null);
                continue;
            }

            // Else there are no timeouts and readable or writable sockets
            // which means there is nothing left to do at all, so exit the run
            // loop.
            break;
        }

        gCurrentActivity = null;

        if (completion != null) {
            completion();
        }
    }

    /**
     * Immediately directly schedules at the head of the global "immediate
     * callback" queue.
     **/
    public static function immediately(f : Void -> Void,
                                       cancellable : Bool) : CancelId
    {
#if AUDIT_ACTIVITY
        if (gCurrentActivity == null) {
            throw "Must schedule calls from within an Activity";
        }
#end
        if (gCurrentActivity.shutdown) {
            throw ActivityError.Shutdown;
        }
        var s = Scheduled.acquire_callme(gCurrentActivity, cancellable, f,
                                         null);
        gImmediate.pushBeforeHead(s);
        gCurrentActivity.immediateCount += 1;
        return s.cancelId;
    }

    /**
     * Immediately directly schedules at the tail of the global
     * "soon callback" queue.
     **/
    public static function soon(act : Activity, f : Void -> Void,
                                onShutdown : Void -> Void,
                                cancellable : Bool) : CancelId
    {
        var activityImpl : ActivityImpl = cast act;
        if (activityImpl.shutdown) {
            throw ActivityError.Shutdown;
        }
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
                     soon(gCurrentActivity, f, null, false);
                 }
                 catch (e : activity.ActivityError) {
                     // Ignore shutdown error here
                 }
             });
        gNormal.pushAfterTail(s);
        (cast(s.activity, ActivityImpl)).normalCount += 1;
        return s.cancelId;
    }

    /**
     * Immediately directly schedules at the tail of the global "later
     * callback" queue.
     **/
    public static function later(f : Void -> Void,
                                 cancellable : Bool) : CancelId
    {
#if AUDIT_ACTIVITY
        if (gCurrentActivity == null) {
            throw "Must schedule calls from within an Activity";
        }
#end
        if (gCurrentActivity.shutdown) {
            throw ActivityError.Shutdown;
        }
        var s = Scheduled.acquire_callme(gCurrentActivity, cancellable, f,
                                         null);
        gLater.pushAfterTail(s);
        return s.cancelId;
    }

    /**
     * Immediately directly schedules in the appropriate timer queue
     **/
    public static function timer(f : Float -> Void, timeout : Float,
                                 cancellable : Bool) : CancelId
    {
#if AUDIT_ACTIVITY
        if (gCurrentActivity == null) {
            throw "Must schedule calls from within an Activity";
        }
#end
        if (gCurrentActivity.shutdown) {
            throw ActivityError.Shutdown;
        }

        if (timeout < 0) {
            timeout = 0;
        }

        var s : Scheduled;
        // If the timeout is 0 or less, then the timer is already expired; no
        // reason to put it into the "future" queue, just put it immediately at
        // the end of the "already expired timer" queue
        if (timeout <= 0) {
            s = Scheduled.acquire_timer(gCurrentActivity, cancellable, f, 0);
            gCurrentActivity.normalCount += 1;
            gExpired.pushAfterTail(s);
        }
        // Insert it into the appropriate part of the future queue
        else {
            s = Scheduled.acquire_timer(gCurrentActivity, cancellable, f,
                                        now() + timeout);
            // If it's the first timer, push it onto the tail of the empty
            // list
            if (gFuture.head == null) {
                gFuture.pushAfterTail(s);
            }
            // Else if it's before the head, put it at the head
            else if (s.when < gFuture.head.when) {
                gFuture.pushBeforeHead(s);
            }
            // Else, find the timer that it should be inserted before, and
            // insert before it
            else {
                var before = gFuture.head.next;
                while ((before != gFuture.head) && (s.when >= before.when)) {
                    before = before.next;
                }
                gFuture.insertBefore(before, s);
            }
            gCurrentActivity.futureCount += 1;
            // If the nearest timeout is now earlier than it was, update the
            // nearest timeout for this activity; this is used when scoring
            // the activities to choose the "most likely to be able to
            // immediately execute a call" functionality of the choose()
            // function
            if (s.when < gCurrentActivity.nearestTimeout) {
                gCurrentActivity.nearestTimeout = s.when;
            }
        }

        return s.cancelId;
    }

    /**
     * The queues are tested in the order "most likely to find the item to
     * cancel" in a hope to get the best performance
     **/
    public static function cancel(cancelId : CancelId)
    {
        Scheduled.cancel(cancelId);
    }

    /**
     * Atomically removes an activity and all of its children from all queues
     **/
    public static function shutdown()
    {
        if (gCurrentActivity == null) {
#if AUDIT_ACTIVITY
            throw "Must call Activity.shutdown() from within an Activity";
#else
            return;
#end
        }

        // Gather the entire set of activities to evict, so that the remove
        // operations can be more efficient, and at the same time, mark them
        // as shutdown
        var all : haxe.ds.ObjectMap<ActivityImpl, Bool> =
            new haxe.ds.ObjectMap<ActivityImpl, Bool>();
        collectForShutdown(gCurrentActivity, all);

        // Eliminate all Scheduled objects for them all
        var test = function(s : Scheduled)
                   {
                       return all.exists(cast s.activity);
                   };
        gImmediate.removeMatches(test, onScheduledActivityRemoved);
        gNormal.removeMatches(test, onScheduledActivityRemoved);
        gLater.removeMatches(test, onScheduledActivityRemoved);
        gExpired.removeMatches(test, onScheduledActivityRemoved);
        gFuture.removeMatches(test, onScheduledActivityRemoved);

        // Eliminate all socket listens for it
        // Gather all sockets
        var sockets : SocketMap = new SocketMap();
        for (socket in gReadableSockets.keys()) {
            sockets.set(socket, true);
        }
        for (socket in gWritableSockets.keys()) {
            sockets.set(socket, true);
        }
        // Eliminate activity from sockets
        for (socket in sockets.keys()) {
            var custom : SocketCustom = cast socket.custom;
            if ((custom.activities[0] != null) && 
                all.exists(custom.activities[0])) {
                socketAble(null, socket, 0, 1, gReadableSockets);
            }
            if ((custom.activities[1] != null) && 
                all.exists(custom.activities[1])) {
                socketAble(null, socket, 1, 0, gWritableSockets);
            }
        }

        // Remove this activity object from its parent.  This will be the only
        // remaining reference to the Activity, outside of any Notifier
        // objects that are holding onto it (and will remove it the next time
        // it would receive a message), and the gCurrentActivity reference,
        // which will go away as soon as the current callack function
        // completes, so once it's out of the Notifiers, it and all of its
        // children (once *they* are out of all Notifiers) are available for
        // garbage collection.
        if (gCurrentActivity.parent != null) {
            gCurrentActivity.parent.children.remove(gCurrentActivity);
        }
    }

    /**
     * Score each activity in the iterator and return the best one
     **/
    public static function choose(activities : Iterator<Activity>) : Activity
    {
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
                return activity;
            }
            // Else, if this activity has a better score than the best
            // activity thus far, use it
            if (score > bestScore) {
                bestScore = score;
                bestActivity = activity;
            }
        }

        return bestActivity;
    }

    public static function setSocketPollInterval(seconds : Float)
    {
        if (seconds < 0) {
            seconds = 0;
        }
        gSocketPollInterval = seconds;
    }

    // In current Activity
    public static function socketReadable(f : Void -> Void,
                                          socket : Socket)
    {
#if AUDIT_ACTIVITY
        if (gCurrentActivity == null) {
            throw ("Must call Scheduler.socketReadable() from within a " +
                   "Activity");
        }
#end
        if (gCurrentActivity.shutdown) {
            throw ActivityError.Shutdown;
        }

        // Just call through to a utility function that can operate on either
        // the readable or writable socket list
        socketAble(f, socket, 0, 1, gReadableSockets);
    }

    // In current Activity
    public static function socketWritable(f : Void -> Void,
                                          socket : Socket)
    {
#if AUDIT_ACTIVITY
        if (gCurrentActivity == null) {
            throw ("Must call Scheduler.socketWritable() from within a " +
                   "Activity");
        }
#end
        if (gCurrentActivity.shutdown) {
            throw ActivityError.Shutdown;
        }

        // Just call through to a utility function that can operate on either
        // the readable or writable socket list
        socketAble(f, socket, 1, 0, gWritableSockets);
    }

    private static inline function now() : Float
    {
        return haxe.Timer.stamp();
    }

    // Helper function that puts the passed-in activity and all of its
    // children recursively into the passed-in array, and also marks each one
    // as 'shutdown' in the process
    private static function collectForShutdown(s : ActivityImpl,
                                    out : haxe.ds.ObjectMap<ActivityImpl, Bool>)
    {
        if (s.children != null) {
            for (c in s.children) {
                collectForShutdown(c, out);
            }
        }
        out.set(s, true);
        s.shutdown = true;
    }

    // Helper function that moves all expired timers from the future list to
    // the expired list
    private static inline function expireTimers()
    {
        var now = now();
        var first = gFuture.head;
        while ((gFuture.head != null) && (gFuture.head.when <= now)) {
            var expired = gFuture.popHead();
            gExpired.pushAfterTail(expired);
            var activityImpl : ActivityImpl = cast expired.activity;
            activityImpl.normalCount += 1;
            removedTimer(activityImpl);
        }
    }

    // Helper function that adds a socket to the readable/writable set
    private static function socketAble(f : Void -> Void,
                                       socket : Socket,
                                       thisIndex : Int,
                                       otherIndex : Int,
                                       m : SocketMap)
    {
        var custom : SocketCustom;

        // Each sys.net.Socket gets a SocketCustom structure in its custom
        // field, to be used by this implementation to store state
        if (socket.custom == null) {
            custom = new SocketCustom();
            socket.custom = custom;
        }
        else {
            custom = cast socket.custom;
        }

        // If f is null, then the Socket is no longer to be watched
        if (f == null) {
            // Remove it from whatever list it was in (readable or writable
            // socket list)
            m.remove(socket);
            // If the socket is now longer readable and no longer writable,
            // remove it completely
            if (custom.activities[otherIndex] == null) {
                socket.custom = null;
                // If there are no more sockets at all, then globally mark
                // gHasSockets as false so that the run loop can know it
                if (Lambda.empty(gReadableSockets) &&
                    Lambda.empty(gWritableSockets)) {
                    gHasSockets = false;
                }
            }
            // Else the socket is still readable or writable, so just null out
            // the appropriate callback
            else {
                custom.activities[thisIndex] = null;
                custom.functions[thisIndex] = null;
            }
        }
        // Else, f is to be set to a real callback
        else {
            // So save that info in the custom state structure
            custom.activities[thisIndex] = gCurrentActivity;
            custom.functions[thisIndex] = f;
            // And add the socket to the readable/writable socket set
            m.set(socket, true);
            // And indicate to the main run loop that there are sockets
            gHasSockets = true;
        }
    }

    // Helper function that runs select over all readable/writable sockets for
    // an optional timeout period
    private static function doSelect(timeout : Null<Float>)
    {
        // Update gMostRecentSelect, which the run loop needs to know in order
        // to know when it's appropriate to poll sockets interleaved with
        // scheduled work
        gMostRecentSelect = now();

        // Run the select.  Uses churn-errific Socket.select.
        gSelectReadableSockets.splice(0, gSelectReadableSockets.length);
        for (s in gReadableSockets.keys()) {
            gSelectReadableSockets.push(s);
        }
        gSelectWritableSockets.splice(0, gSelectWritableSockets.length);
        for (s in gWritableSockets.keys()) {
            gSelectWritableSockets.push(s);
        }
        var r = Socket.select(gSelectReadableSockets, gSelectWritableSockets,
                              null, timeout);
        
        // For each writable socket, schedule a "soon" callback at the head of
        // the "soon callback" list, which causes the callback to occur before
        // any "soon" callbacks.  Note that socket writable callbacks are
        // scheduled before socket readable callbacks, just in case the write
        // operation that may occur in the callback prompts more data to be
        // available in the read
        var i = 0;
        while (i < r.write.length) {
            var custom : SocketCustom = cast (r.write[i++].custom);
            soon(custom.activities[1], custom.functions[1], null, false);
        }
        
        // For each readable socket, schedule a "normal" callback at the head
        // of the "normal callback" list, which causes the callback to occur
        // before any "soon" callbacks.
        i = 0;
        while (i < r.read.length) {
            var custom : SocketCustom = cast (r.read[i++].custom);
            soon(custom.activities[0], custom.functions[0], null, false);
        }
    }

    // Helper function called when a timer callback has been removed from an
    // activity (either because it has gone off or because it's been
    // cancelled).  In this situation, need to look to see if there is another
    // pending timer so that the "nearest timeout" can be updated for an
    // activity, necessary for proper scoring of activities in the choose()
    // function.
    private static inline function removedTimer(a : ActivityImpl)
    {
        if ((--a.futureCount > 0) && (gFuture.head != null)) {
            var s = gFuture.head;
            do {
                if (s.activity == a) {
                    a.nearestTimeout = s.when;
                    break;
                }
                s = s.next;
            } while (s != gFuture.head);
        }
    }

    // Runs a callback that was scheduled previously and now is to be run
    private static inline function runScheduled(s : Scheduled)
    {
        // Make sure that gCurrentActivity is set to the activity of the
        // callback so that the code run in the callback knows what the
        // "current activity" is
        gCurrentActivity = cast s.activity;
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
#if AUDIT_ACTIVITY
        if (Mutex.activityHasLockedMutex(gCurrentActivity)) {
            throw MutexStillLocked;
        }
#end
        // if an exception was thrown from the scheduled function call ...
        if (thrown != null) {
            // If the current activity declared a "caught" function to be
            // called when an exception occurs, call it.  If it throws an
            // exception, then the exception doesn't get caught and ends up
            // throwing all the way out of the run() function
            if (gCurrentActivity.uncaught != null) {
                gCurrentActivity.uncaught(thrown);
            }
            // Else, there is no exception handler for this activity, so shut
            // down the activity
            else {
                shutdown();
            }
        }
        // activity no longer running, set gCurrentActivity to null (helps
        // with gc)
        gCurrentActivity = null;
    }

    private static function onScheduledActivityRemoved(s : Scheduled)
    {
        if (s.onShutdown != null) {
            s.onShutdown();
        }
    }

    private static var gCurrentActivity : ActivityImpl = null;
    private static var gImmediate : ScheduledList = new ScheduledList();
    private static var gNormal : ScheduledList = new ScheduledList();
    private static var gLater : ScheduledList = new ScheduledList();
    private static var gExpired : ScheduledList = new ScheduledList();
    // Arranged in increasing 'when' order
    private static var gFuture : ScheduledList = new ScheduledList();
    private static var gSocketPollInterval : Float = 0.1; // 1/10 s = 100 ms
    private static var gMostRecentSelect : Float = 0;
    private static var gHasSockets : Bool = false;
    private static var gReadableSockets : SocketMap = new SocketMap();
    private static var gWritableSockets : SocketMap = new SocketMap();
    private static var gSelectReadableSockets : SocketArray = new SocketArray();
    private static var gSelectWritableSockets : SocketArray = new SocketArray();
}


private typedef ScheduledList = FastList<Scheduled>;
private typedef SocketMap = haxe.ds.ObjectMap<Socket, Bool>;
private typedef SocketArray = Array<Socket>;


private class ActivityImpl extends Activity
{
    // If non-null, called when an uncaught exception occurs on this Activity
    public var uncaught : Dynamic -> Void;
    // True after the Activity has been shutdown
    public var shutdown : Bool;
    // Parent, may be null
    public var parent : ActivityImpl;
    // Children
    public var children : Array<ActivityImpl>;
    // Number of scheduled immediate calls
    public var immediateCount : Int;
    // Number of scheduled 'soon' and 'expired timeout' calls
    public var normalCount : Int;
    // Number of scheduled 'future timeout' calls
    public var futureCount : Int;
    // Timeout value of nearest future timeout
    public var nearestTimeout : Float;

    public function new(uncaught : Dynamic -> Void, name : String)
    {
        super(name);
        
        this.uncaught = uncaught;
        this.shutdown = false;
        this.parent = cast Scheduler.getCurrentActivity();
        this.children = null;
        this.immediateCount = 0;
        this.normalCount = 0;
        this.futureCount = 0;
        this.nearestTimeout = 0;
        if (this.parent != null) {
            if (this.parent.children == null) {
                this.parent.children = [ ];
            }
            this.parent.children.push(this);
        }
    }

    // Returns a score for use in choosing which Activity to return from
    // Scheduler.choose()
    public function getScore() : Float
    {
        // Shutdown activities get an immediate score of -1, so that they will
        // be the first activities seen by any schedule attempts, and the
        // caller will be notified ASAP about shutdown activities in the list
        if (this.shutdown) {
            return -1;
        }

        // If it's the currently running activity, give it a score of 0
        // since it's currently executing a call
        if (this == Scheduler.getCurrentActivity()) {
            return 0;
        }

        // Score of 0 if there is work already scheduled to be done
        if ((this.immediateCount > 0) || (this.normalCount > 0)) {
            return 0;
        }

        // If there are no future timers, then score -1
        if (this.futureCount == 0) {
            return -1;
        }

        // Return the nearest timeout
        return this.nearestTimeout;
    }
}


private class SocketCustom
{
    // index 0 = readable, index 1 = writable
    public var activities : Array<ActivityImpl>;
    public var functions : Array<Void -> Void>;

    public function new()
    {
        this.activities = [ null, null ];
        this.functions = [ null, null ];
    }
}
