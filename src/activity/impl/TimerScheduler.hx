/**
 * Copyright 2015 TiVo, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/
package activity.impl;

import activity.Activity;
import activity.Mutex;

/**
 * This class implements the Scheduler on single threaded platforms that do
 * not control the main loop and must rely on haxe.Timer.  The Scheduler is
 * used by the Activity API to actually accomplish the work of scheduling and
 * running Activity callbacks.
 **/
class TimerScheduler
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
     * The run() function cannot actually run Activity callbacks; Activity
     * callbacks must be run via haxe Timers.
     **/
    public static function run(completion : Void -> Void)
    {
        // Save the completion
        gCompletion = completion;

        // Activity the first timer callback
        gRunTimer = new RunTimer(0);
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
        pushHead(gImmediate, s);
        gCurrentActivity.immediateCount += 1;
        if (gRunTimer == null) {
            gRunTimer = new RunTimer(0);
        }
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
        /**
         * If onShutdown is not null, schedule a closure that schedules it
         * onto the calling Activity when the target activity actually shuts
         * down, catching and ignoring a shutdown error if the calling
         * activity itself has already shut down.
         **/
        var s = Scheduled.acquire_callme(activityImpl, cancellable, f,
                                         (onShutdown == null) ? null :
                                         function ()
                                         {
                                             try {
                                                 soon(gCurrentActivity, f,
                                                      null, false);
                                             }
                                             catch (e : activity.ActivityError) {
                                                 // Ignore shutdown error here
                                             }
                                         });
        pushTail(gNormal, s);
        s.activity.normalCount += 1;
        if (gRunTimer == null) {
            gRunTimer = new RunTimer(0);
        }
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
        pushTail(gLater, s);
        if (gRunTimer == null) {
            gRunTimer = new RunTimer(0);
        }
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

        var s : Scheduled;
        /**
         * If the timeout is 0 or less, then the timer is already expired; no
         * reason to put it into the "future" queue, just put it immediately at
         * the end of the "already expired timer" queue
         **/
        if (timeout <= 0) {
            s = Scheduled.acquire_timer(gCurrentActivity, cancellable, f, 0);
            gCurrentActivity.normalCount += 1;
            pushTail(gExpired, s);
        }
        /**
         * Insert it into the appropriate part of the future queue
         **/
        else {
            s = Scheduled.acquire_timer(gCurrentActivity, cancellable, f,
                                        now() + timeout);
            /**
             * If it's the first timer, push it onto the tail of the empty
             * list
             **/
            if (gFuture.head == null) {
                pushTail(gFuture, s);
            }
            /**
             * Else if it's before the head, put it at the head
             **/
            else if (s.when < gFuture.head.when) {
                pushHead(gFuture, s);
            }
            /**
             * Else, find the timer that it should be inserted before, and
             * insert before it
             **/
            else {
                var before = gFuture.head.next;
                while ((before != gFuture.head) && (s.when >= before.when)) {
                    before = before.next;
                }
                insert(gFuture, before, s);
            }
            gCurrentActivity.futureCount += 1;
            /**
             * If the nearest timeout is now earlier than it was, update the
             * nearest timeout for this activity; this is used when scoring
             * the activities to choose the "most likely to be able to
             * immediately execute a call" functionality of the choose()
             * function
             **/
            if (s.when < gCurrentActivity.nearestTimeout) {
                gCurrentActivity.nearestTimeout = s.when;
            }
        }

        if (gRunTimer == null) {
            gRunTimer = new RunTimer(0);
        }

        return s.cancelId;
    }

    /**
     * The queues are tested in the order "most likely to find the item to
     * cancel" in a hope to get the best performance
     **/
    public static function cancel(cancelId : CancelId)
    {
        var s : Scheduled;
        // Most likely to cancel future timers
        if ((s = removeByCancelId(gFuture, cancelId)) != null) {
            s.activity.futureCount -= 1;
            removedTimer(s.activity);
        }
        // Next most likely to cancel expired timers
        else if ((s = removeByCancelId(gExpired, cancelId)) != null) {
            s.activity.normalCount -= 1;
        }
        // Next most likely to cancel normal callmes
        else if ((s = removeByCancelId(gNormal, cancelId)) != null) {
            s.activity.normalCount -= 1;
        }
        // Next most likely to cancel later callmes
        else if ((s = removeByCancelId(gLater, cancelId)) != null) {
            // later callbacks are not counted
        }
        // Least likely to cancel immediate callmes
        else if ((s = removeByCancelId(gImmediate, cancelId)) != null) {
            s.activity.immediateCount -= 1;
        }

#if AUDIT_ACTIVITY
        if ((s != null) && (gCurrentActivity != s.activity)) {
            throw ("Must cancel calls from the same Activity " +
                   "that scheduled the call being cancelled");
        }
#end
    }

    /**
     * Atomically removes an activity and all of its children from all queues
     **/
    public static function shutdown()
    {
#if AUDIT_ACTIVITY
        if (gCurrentActivity == null) {
            throw "Must call Activity.shutdown() from within a Activity";
        }
#end
        // Gather the entire set of activities to evict, so that the remove
        // operations can be more efficient, and at the same time, mark them
        // as shutdown
        var all : haxe.ds.ObjectMap<ActivityImpl, Bool> =
            new haxe.ds.ObjectMap<ActivityImpl, Bool>();
        collectForShutdown(gCurrentActivity, all);

        // Eliminate all Scheduled objects for them all
        var test = function(scheduled : Scheduled)
                   {
                       return all.exists(scheduled.activity);
                   };
        removeActivities(gImmediate, test);
        removeActivities(gNormal, test);
        removeActivities(gLater, test);
        removeActivities(gExpired, test);
        removeActivities(gFuture, test);

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
            // already been determined to be the best, no need to
            // re-evaluate it.
            if (activity == bestActivity) {
                continue;
            }
            // Get the score for this Activity
            var score = cast(activity, ActivityImpl).getScore();
            // If score < 0, then this activity is not activityd at all and
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
        // No-op
    }

#if js
    public static function webSocketOnOpen(webSocket : js.html.WebSocket,
                                           sender : activity.NotificationSender)
    {
        if (sender == null) {
            webSocket.onopen = null;
        }
        else {
            webSocket.onopen = function (d : Dynamic)
                               {
                                   sender.send();
                               };
        }
        updateWebSocket(webSocket);
    }

    public static function webSocketOnMessage(webSocket : js.html.WebSocket,
                                       sender : activity.MessageSender<Dynamic>)
    {
        if (sender == null) {
            webSocket.onmessage = null;
        }
        else {
            webSocket.onmessage = function (d : Dynamic)
                                  {
                                      sender.send(d);
                                  };
        }
        updateWebSocket(webSocket);
    }

    public static function webSocketOnError(webSocket : js.html.WebSocket,
                                           sender : activity.NotificationSender)
    {
        if (sender == null) {
            webSocket.onerror = null;
        }
        else {
            webSocket.onerror = function (d : Dynamic)
                                {
                                    sender.send();
                                };
        }
        updateWebSocket(webSocket);
    }

    public static function webSocketOnClose(webSocket : js.html.WebSocket,
                                       sender : activity.MessageSender<Dynamic>)
    {
        if (sender == null) {
            webSocket.onclose = null;
        }
        else {
            webSocket.onclose = function (d : Dynamic)
                                {
                                    sender.send(d);
                                };
        }
        updateWebSocket(webSocket);
    }

    private static function updateWebSocket(webSocket : js.html.WebSocket)
    {
        if ((webSocket.onopen == null) &&
            (webSocket.onmessage == null) &&
            (webSocket.onerror == null) &&
            (webSocket.onclose == null)) {
            if (gWebSockets.exists(webSocket)) {
                gWebSockets.remove(webSocket);
                gWebSocketCount -= 1;
            }
        }
        else {
            if (!gWebSockets.exists(webSocket)) {
                gWebSockets.set(webSocket, true);
                gWebSocketCount += 1;
            }
        }
    }

#end

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
            var expired = popHead(gFuture);
            pushTail(gExpired, expired);
            expired.activity.normalCount += 1;
            removedTimer(expired.activity);
        }
    }

    public static function runOnce()
    {
        // Run all immediate calls if there are any
        var s = popHead(gImmediate);
        if (s != null) {
            do {
                s.activity.immediateCount -= 1;
                runScheduled(s);
                s = popHead(gImmediate);
            } while (s != null);
        }
        // Else run something else ...
        else {
            // Move expired timers from future list to expired list
            expireTimers();
            
            // Run an expired timer if there is one
            var s = popHead(gExpired);
            if (s != null) {
                s.activity.normalCount -= 1;
                runScheduled(s);
            }
            // Else run something else ...
            else {
                // Run a normal call if there is one
                s = popHead(gNormal);
                if (s != null) {
                    s.activity.normalCount -= 1;
                    runScheduled(s);
                }
                // Else run something else ...
                else {
                    // Run later call if there is one
                    s = popHead(gLater);
                    if (s != null) {
                        runScheduled(s);
                    }
                }
            }
        }

        // If there are any outstanding immediate, normal, later, or expired
        // calls to make, schedule a zero length system timer to call them
        if ((gImmediate.head != null) ||
            (gNormal.head != null) ||
            (gLater.head != null) ||
            (gExpired.head != null)) {
            gRunTimer = new RunTimer(0);
        }
        // Else if there are any outstanding timers, schedule a system timer
        // to call back at the earliest one
        else if (gFuture.head != null) {
            var timeout = gFuture.head.when - now();
            if (timeout < 0) {
                timeout = 0;
            }
            gRunTimer = new RunTimer(timeout);
        }
        // Else, don't register any timer callback since there is nothing
        // scheduled to be run.  Javascript may have outstanding web socket
        // callbacks registered though, and if it does, simply wait for them.
        // But if this is not Javascript or if it is Javascript and there are
        // no outstanding web sockets, call the completion function if there
        // is one.
        else {
            gRunTimer = null;
#if js
            if (gWebSocketCount == 0) {
#else
            if (true) {
#end
                if (gCompletion != null) {
                    gCompletion();
                }
            }
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
        gCurrentActivity = s.activity;
        // Run the callback in a try block that catches exceptions and feeds
        // them to the "uncaught" function of the activity if there is one
        var thrown : Dynamic = null;
        try {
            // If the scheduled callback had a timer function in f_timer, then
            // it was a scheduled timer callback and needs to be called with
            // the "number of seconds past the scheduled timeout that this
            // callback is occurring"
            if (s.f_timer != null) {
                s.f_timer(now() - s.when);
            }
            // Else the scheduled callback must have a normal call me function
            // in f_callme, which is called with no arguments
            else {
                s.f_callme();
            }
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
            // down the activity and throw an exception out of run()
            else {
                shutdown();
                gCurrentActivity = null;
                throw thrown;
            }
        }
        // activity no longer running, set gCurrentActivity to null (helps
        // with gc)
        gCurrentActivity = null;
    }

    // Helper function to push a Scheduled object after the tail of a
    // ScheduledList
    private static function pushTail(list : ScheduledList, e : Scheduled)
    {
        if (list.head == null) {
            e.prev = e;
            e.next = e;
            list.head = e;
        }
        else {
            e.next = list.head;
            e.prev = list.head.prev;
            list.head.prev.next = e;
            list.head.prev = e;
        }
    }

    // Helper function to push a Scheduled object before the head of a
    // ScheduledList
    private static function pushHead(list : ScheduledList, e : Scheduled)
    {
        pushTail(list, e);
        list.head = e;
    }

    // Helper function to insert a Scheduled object into a ScheduledList,
    // just before a Scheduled object already on the ScheduledList
    private static function insert(list : ScheduledList, before : Scheduled,
                                   toInsert : Scheduled)
    {
        toInsert.next = before;
        toInsert.prev = before.prev;
        before.prev.next = toInsert;
        before.prev = toInsert;
    }

    // Helper function to pop the head of a ScheduledList
    private static function popHead(list : ScheduledList) : Scheduled
    {
        if (list.head == null) {
            return null;
        }
        var ret = list.head;
        if (list.head.next == list.head) {
            list.head = null;
        }
        else {
            list.head.prev.next = list.head.next;
            list.head.next.prev = list.head.prev;
            list.head = list.head.next;
        }
        ret.prev = null;
        ret.next = null;
        return ret;
    }

    // Helper function to remove a Scheduled object from a ScheduledList,
    // where the Scheduled object has a given cancel id.  Returns the removed
    // Scheduled object, or null if none was removed
    private static function removeByCancelId(list : ScheduledList,
                                             cancelId : CancelId) : Scheduled
    {
        if (list.head == null) {
            return null;
        }

        var current = list.head;
        do {
            if (current.cancelId == cancelId) {
                if (current == list.head) {
                    if (current.next == current) {
                        list.head = null;
                        return current;
                    }
                    else {
                        list.head = current.next;
                    }
                }
                current.prev.next = current.next;
                current.next.prev = current.prev;
                return current;
            }
            current = current.next;
        } while (current != list.head);

        return null;
    }

    // Helper function to remove all Scheduled objects from a ScheduledList
    // for a given Activity.
    private static function removeActivities(list : ScheduledList,
                                             test : Scheduled -> Bool)
    {
        if (list.head == null) {
            return;
        }

        // Look at the entire list except for the head
        var current = list.head.next;
        while (current != list.head) {
            if (test(current)) {
                if (current.onShutdown != null) {
                    current.onShutdown();
                }
                current.prev.next = current.next;
                current.next.prev = current.prev;
            }
            current = current.next;
        }

        // Now look at the head
        if (test(current)) {
            if (current.onShutdown != null) {
                current.onShutdown();
            }
            popHead(list);
        }
    }

    private static var gCurrentActivity : ActivityImpl = null;
    private static var gRunTimer : RunTimer = null;
    private static var gCompletion : Void -> Void = null;
    private static var gImmediate : ScheduledList = { head : null };
    private static var gNormal : ScheduledList = { head : null };
    private static var gLater : ScheduledList = { head : null };
    private static var gExpired : ScheduledList = { head : null };
    // Arranged in increasing 'when' order
    private static var gFuture : ScheduledList = { head : null };
#if js
    private static var gWebSockets : WebSocketMap = new WebSocketMap();
    private static var gWebSocketCount : Int = 0;
#end
}


private typedef ScheduledList = { head : Scheduled };

#if js
private typedef WebSocketMap = haxe.ds.ObjectMap<js.html.WebSocket, Bool>;
#end


private class ActivityImpl extends Activity
{
    // If non-null, alled when an uncaught exception occurs on this Activity
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


private class Scheduled
{
    public var cancelId(default, null) : CancelId;
    public var activity(default, null) : ActivityImpl;
    // The following could be handled by an enum, but enums churn, and to
    // avoid that, don't use an enum
    public var f_callme(default, null) : Void -> Void;      // only for callme
    public var onShutdown(default, null) : Void -> Void;    // only for callme
    public var f_timer(default, null) : Float -> Void;      // only for timer
    public var when(default, null) : Float;                 // only for timer
    public var prev : Scheduled;
    public var next : Scheduled;

    // Use pooling to reduce churn on these very frequently allocated objects
    public static function acquire_callme(activity : ActivityImpl,
                                          cancellable : Bool,
                                          f : Void -> Void,
                                          onShutdown : Void -> Void) : Scheduled
    {
        var ret = acquire(activity, cancellable);
        ret.f_callme = f;
        ret.onShutdown = onShutdown;
        // prev and null will be set by the caller
        return ret;
    }

    public static function acquire_timer(activity : ActivityImpl,
                                         cancellable : Bool,
                                         f : Float -> Void,
                                         when : Float) : Scheduled
    {
        var ret = acquire(activity, cancellable);
        ret.f_timer = f;
        ret.when = when;
        // prev and null will be set by the caller
        return ret;
    }

    public static function release(s : Scheduled)
    {
        s.cancelId = null;
        s.activity = null;
        s.f_callme = null;
        s.onShutdown = null;
        s.f_timer = null;
        s.prev = null;
        s.next = null;
        gPool.push(s);
    }

    private function new()
    {
    }

    private static function acquire(activity : ActivityImpl, cancellable : Bool)
    {
        var ret : Scheduled;

        if (gPool.length == 0) {
            ret = new Scheduled();
        }
        else {
            ret = gPool.pop();
        }

        if (cancellable) {
            ret.cancelId = { };
        }
        ret.activity = activity;
        return ret;
    }

    private static var gPool : Array<Scheduled> = [ ];
}


private class RunTimer extends haxe.Timer
{
    // Timeout is in seconds
    public function new(timeout : Float)
    {
        super(Std.int(timeout * 1000));
    }

    override function run()
    {
        this.stop();
        TimerScheduler.runOnce();
    }
}
