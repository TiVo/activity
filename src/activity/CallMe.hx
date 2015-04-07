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
package activity;

import activity.Activity;
import activity.impl.Scheduler;

/**
 * CallMeWhen identifies the ways in which a CallMe may be scheduled to run.
 **/
enum CallMeWhen
{
    /**
     * A CallMe that is scheduled to run Immediately will always be the
     * next function run on the Activity that the CallMe was scheduled to run
     * on, except that any CallMes subsequently scheduled for Immediately will
     * occur first.
     **/
    Immediately;
    /**
     * A CallMe that is scheduled to run Soon runs after all Immediately
     * CallMes, before all Later CallMes, and after any Timer or Socket calls.
     **/
    Soon;
    /**
     * A CallMe that is scheduled to run Later only runs when there are no
     * other calls to be made on the Activity.  Multiple Later CallMes are
     * called in the order that they were scheduled.
     **/
    Later;
}


/**
 * A CallMe executes a deferred call into an Activity.  When a CallMe is
 * created and then set up to be called (by setting the onCalled parameter),
 * it will be scheduled to call into its onCalled function in the Activity
 * that set onCalled.
 **/
class CallMe
{
    /**
     * This parameter is set by the Activity on which the CallMe should run to
     * the function closure to be run within that Activity.  Setting this
     * parameter immediately schedules the CallMe to be run according to the
     * 'when' semantics of the CallMe (Immediately, Soon, or Later).
     * Re-setting this parameter to any value (even the same value) cancels
     * the existing callback, and if the new value is non-null, reschedules
     * the call according to the CallMe's scheduling semantics.  When this
     * property is set to null, it cancels the CallMe.
     **/
    public var onCalled(null, set_onCalled) : Void -> Void;

    /**
     * Create a CallMe.  The CallMe is not scheduled until the onCalled
     * property is set to non-null.
     *
     * @param when indicates how the CallMe will be scheduled when it is
     *        scheduled (which occurs when the onCalled property is set to
     *        non-null).
     **/
    public function new(?when : CallMeWhen)
    {
        mWhen = (when == null) ? Soon : when;
        mCancelId = null;
    }


    /** **********************************************************************
     * The following static API is useful for scheduling single closure
     * functions without having to create CallMe objects for those situations
     * in which that is more convenient.
     ********************************************************************** **/

    /**
     * Schedules a function closure to be called in the current Activity
     * immediately upon return from the currently executing Activity function.
     * The only function closure that could be called earlier would be one
     * scheduled via a subsequent call to immediately().
     *
     * If the Activity object has already been shut down, this function will
     * throw ActivityError.Shutdown and the call will not be scheduled.
     *
     * @param f is the function to call as soon as possible in the calling
     *        Activity
     * @param cancellable if true, the scheduled call may be cancelled by the
     *        returned CancelId; if false, the returned CancelId is null, and
     *        the call is not cancellable.  Passing true uses slightly more
     *        system resources than passing false, so if the call is known to
     *        never need to be cancelled, pass false.  Defaults to true.
     * @return a CancelId uniquely identifying the scheduled call so that it
     *         can be cancelled later if necessary, or null if cancellable
     *         was false
     **/
    public static function immediately(f : Void -> Void,
                                    cancellable : Bool = false) : Null<CancelId>
    {
        return Scheduler.immediately(f, false);
    }

    /**
     * Schedules a function closure to be called in the current Activity
     * "soon", which means after any "immediate" functions, and before any
     * "later" functions, but after any expired timers or socket callbacks.
     *
     * If the Activity object has already been shut down, this function will
     * throw ActivityError.Shutdown and the call will not be scheduled.
     *
     * @param f is the function to call after "immediate" callbacks, and after
     *        timer and socket callbacks, but before any "later" callbacks.
     * @param cancellable if true, the scheduled call may be cancelled by the
     *        returned CancelId; if false, the returned CancelId is null, and
     *        the call is not cancellable.  Passing true uses slightly more
     *        system resources than passing false, so if the call is known to
     *        never need to be cancelled, pass false.  Defaults to true.
     * @return a CancelId uniquely identifying the scheduled call so that it
     *         can be cancelled later if necessary, or null if cancellable
     *         was false
     **/
    public static function soon(f : Void -> Void,
                                cancellable : Bool = false) : Null<CancelId>
    {
        var currentActivity = Scheduler.getCurrentActivity();
#if AUDIT_ACTIVITY
        if (currentActivity == null) {
            throw "Must call CallMe.soon() from within an Activity";
        }
#end
        return Scheduler.soon(currentActivity, f, null, false);
    }

    /**
     * Schedules a function closure to be called in the current Activity
     * "eventually", which means after any other scheduled functions have
     * completed.  A "later" callback is only called when there are no other
     * callbacks to be made for the current Activity.  In this way it acts as
     * an "idle" callback.
     *
     * If the Activity object has already been shut down, this function will
     * throw ActivityError.Shutdown and the call will not be scheduled.
     *
     * @param f is the function to call when there are no more callbacks to be
     *        made on the current Activity.
     * @param cancellable if true, the scheduled call may be cancelled by the
     *        returned CancelId; if false, the returned CancelId is null, and
     *        the call is not cancellable.  Passing true uses slightly more
     *        system resources than passing false, so if the call is known to
     *        never need to be cancelled, pass false.  Defaults to true.
     * @return a CancelId uniquely identifying the scheduled call so that it
     *         can be cancelled later if necessary, or null if cancellable
     *         was false
     **/
    public static function later(f : Void -> Void,
                                cancellable : Bool = false) : Null<CancelId>
    {
        return Scheduler.later(f, false);
    }

    /**
     * Cancels a previously scheduled call that was scheduled via
     * immediately(), soon(), or later().  This call must be made from the
     * same Activity that scheduled the call.
     *
     * @param cancelId is the CancelId of the call to cancel, as returned by
     *        immediately(), soon(), or later() (when the cancellable
     *        parameter was passed as true to that call)
     **/
    public static function cancel(cancelId : CancelId)
    {
        Scheduler.cancel(cancelId);
    }


    // ------------------------------------------------------------------------
    // Private implementation follows -- please ignore.
    // ------------------------------------------------------------------------

    private function set_onCalled(f : Void -> Void) : Void -> Void
    {
        if (mCancelId != null) {
            Scheduler.cancel(mCancelId);
        }
        
        if (f == null) {
            mCancelId = null;
        }
        else {
            switch (mWhen) {
            case Immediately:
                mCancelId = Scheduler.immediately(f, true);
            case Soon:
                var currentActivity = Scheduler.getCurrentActivity();
#if AUDIT_ACTIVITY
                if (currentActivity == null) {
                    throw "Must set CallMe.onCalled from within an Activity";
                }
#end
                mCancelId = Scheduler.soon(currentActivity, f, null, true);
            case Later:
                mCancelId = Scheduler.later(f, true);
            }
        }

        return f;
    }

    private var mWhen : CallMeWhen;
    private var mCancelId : CancelId;
}
