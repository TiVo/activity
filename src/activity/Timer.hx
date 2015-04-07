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
 * A Timer executes a call in an Activity after a timeout period has elapsed.
 **/
class Timer
{
    /**
     * Sets the interval on which the timer will be run.  If the timer is
     * currently outstanding, its interval is updated to reflect this new
     * value.  interval is a number of seconds.
     **/
    public var interval(get_interval, set_interval) : Float;

    /**
     * When set to true, the Timer will automatically re-schedule itself after
     * having expired and had its onTimeout function called; if false, it will
     * not.
     **/
    public var repeating(get_repeating, set_repeating) : Bool;

    /**
     * This provides the function closure to call in the Activity that set the
     * onTimeout property when the timeout expires.  Setting this parameter
     * and then calling start() causes the timer to be run start.  Re-setting
     * this parameter to any value (even the same value) cancels the existing
     * timer, and if the new value is non-null, reschedules the timer
     * according to the timer interval.  When this property is set to null, it
     * cancels the Timer.
     *
     * The timer callback function is passed the number of seconds past the
     * ideal timeout time that this function is being called.  Thus, if the
     * timer 'misses' by 0.1 seconds (because of unavoidable latencies), the
     * value passed in will be 0.1.
     **/
    public var onTimeout(null, set_onTimeout) : Float -> Void;

    /**
     * Create a new Timer.  The Timer must, at a minimum, have its onTimeout
     * function set, and then have start() called, in order to become
     * scheduled.
     **/
    public function new()
    {
        mInterval = 0;
        mRepeating = false;
        mTimerFunction = null;
        mCancelId = null;
    }

    /**
     * Starts a Timer that has a non-null onTimeout and hasn't been started
     * yet.  Is a no-op if the Timer has a null onTimeout, or has already been
     * started.  If the Timer has already been started and completed, this
     * call will re-schedule it according to its interval.
     **/
    public function start()
    {
        if ((mCancelId != null) || (mTimerFunction == null)) {
            return;
        }

        mCancelId = once(mTimerFunction, mInterval, true);
    }


    /** **********************************************************************
     * The following static API is useful for scheduling single closure
     * functions without having to create CallMe objects for those situations
     * in which that is more convenient.
     ********************************************************************** **/

    /**
     * Schedules a function closure to be called in the current Activity after
     * a given period of time has elapsed.  As soon as the given period of
     * time has elapsed (i.e. the "timer has fired"), the callback will be
     * scheduled to be made.  The only functions which take priority over
     * timer callbacks are "immediate" callbacks.  Expired timer callbacks are
     * made before socket, "soon", and "later" callbacks.
     *
     * If the Activity object has already been shut down, this function will
     * throw ActivityError.Shutdown and the call will not be scheduled.
     *
     * @param f is the function to call when the timeout period has passed
     * @param timeout is the number of seconds from 'now' at which time the
     *        callback will be made.  For example, 0.001 is a microsecond
     *        timeout. The timer callback function is passed the number of
     *        seconds past the ideal timeout time that this function is being
     *        called.  Thus, if the timer 'misses' by 0.1 seconds (because of
     *        unavoidable latencies), the value passed in will be 0.1.
     * @param cancellable if true, the scheduled call may be cancelled by the
     *        returned CancelId; if false, the returned CancelId is null, and
     *        the call is not cancellable.  Passing true uses slightly more
     *        system resources than passing false, so if the call is known to
     *        never need to be cancelled, pass false.  Defaults to true.
     * @return a CancelId uniquely identifying the scheduled call so that it
     *         can be cancelled later if necessary, or null if cancellable was
     *         false
     **/
    public static function once(f : Float -> Void, timeout : Float,
                                cancellable : Bool = true) : Null<CancelId>
    {
        return Scheduler.timer(f, timeout, cancellable);
    }

    /**
     * Cancels a previously scheduled timer that was scheduled via once().  If
     * the call has already been made, this call has no effect.  Must be
     * called from the same Activity that scheduled the timer.
     *
     * @param cancelId is the CancelId of the call to cancel, as returned by
     *        once() (when the cancellable parameter was passed as true to
     *        that call)
     **/
    public static function cancel(cancelId : CancelId)
    {
        Scheduler.cancel(cancelId);
    }


    // ------------------------------------------------------------------------
    // Private implementation follows -- please ignore.
    // ------------------------------------------------------------------------

    private function get_interval() : Float
    {
        return mInterval;
    }

    private function set_interval(value : Float) : Float
    {
        if (mInterval != value) {
            mInterval = value;

            if (mCancelId != null) {
                cancel(mCancelId);
                mCancelId = once(mTimerFunction, mInterval, true);
            }
        }

        return value;
    }

    private function get_repeating() : Bool
    {
        return mRepeating;
    }

    private function set_repeating(value : Bool) : Bool
    {
        mRepeating = value;

        return value;
    }
   
    private function set_onTimeout(f : Float -> Void) : Float -> Void
    {
        if (mCancelId != null) {
            cancel(mCancelId);
            mCancelId = null;
        }

        if (f == null) {
            mTimerFunction = null;
        }
        else {
            mTimerFunction = function (miss : Float)
                             {
                                 mCancelId = null;
                                 f(miss);
                                 if (mRepeating) {
                                     this.start();
                                 }
                             };
        }

        return f;
    }

    private var mInterval : Float;
    private var mRepeating : Bool;
    private var mTimerFunction : Float -> Void;
    private var mCancelId : CancelId;
}
