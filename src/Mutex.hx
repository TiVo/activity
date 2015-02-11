/** *************************************************************************
 * Mutex.hx
 *
 * Copyright 2014 TiVo, Inc.
 ************************************************************************** **/

package activity;

import activity.impl.Scheduler;

#if cpp
typedef SystemMutex = cpp.vm.Mutex;
#elseif neko
typedef SystemMutex = neko.vm.Mutex;
#elseif cs
#error Not sure how to implement this for the cs target
#elseif java
typedef SystemMutex = java.vm.Mutex;
#end

/**
 * A Mutex can be used to ensure that only one context of execution at a time
 * enters a region of code.  This can be used to prevent simultaneous access
 * to shared data if the shared data is only referenced within code run while
 * the Mutex is locked.
 *
 * An important aspect of activity.Mutex is that such a Mutex *cannot* remain
 * locked when the Activity function which has locked it returns.  All Mutexes
 * must be unlocked before the currently executing function of the current
 * Activity returns.  Otherwise, single threaded platforms would always
 * deadlock.  Note that this does not mean that a Mutex cannot be locked
 * across function calls that happen *within* an activity callback.
 *
 * If AUDIT_ACTIVITY is enabled, an exception will be thrown if any Mutex is
 * still locked when an activity function returns.
 **/
class Mutex
{
    /**
     * Create a new Mutex, initially in the unlocked state.
     **/
    public function new()
    {
#if (cpp || neko || java)
       mSystemMutex = new SystemMutex();
#end
    }

    /**
     * Lock a Mutex.  If the Mutex is already locked, waits until it is
     * unlocked before returning.  The Mutex must be unlocked before the
     * currently executing Scheduler callback completes (but not before the
     * currently executing function completes, unless the currently executing
     * funtion *is* the Scheduler callback).
     **/
    public function lock()
    {
#if (cpp || neko || java)
        mSystemMutex.acquire();
#end

#if AUDIT_ACTIVITY
        var activity = Scheduler.getCurrentActivity();
        if (activity == null) {
            throw "Mutex must be locked within an activity";
        }
        var mutexes : Array<Mutex>;

#if (cpp || neko || java)
        gMapLock.acquire();
#end

        if (gMap.exists(activity)) {
            mutexes = gMap.get(activity);
        }
        else {
            mutexes = [ ];
            gMap.set(activity, mutexes);
        }
        mutexes.push(this);

#if (cpp || neko || java)
        gMapLock.release();
#end

#end
    }

    /**
     * Unlock a locked Mutex.
     **/
    public function unlock()
    {
#if AUDIT_ACTIVITY
        var activity = Scheduler.getCurrentActivity();
        if (activity == null) {
            throw "Mutex must be unlocked within an activity";
        }

#if (cpp || neko || java)
        gMapLock.acquire();
#end

        if (gMap.exists(activity)) {
            var mutexes = gMap.get(activity);
            mutexes.remove(this);
            if (mutexes.length == 0) {
                gMap.remove(activity);
            }
        }

#if (cpp || neko || java)
        gMapLock.release();
#end

        mSystemMutex.release();
#end
    }


    // ------------------------------------------------------------------------
    // Private implementation follows -- please ignore.
    // ------------------------------------------------------------------------

#if AUDIT_ACTIVITY
    public static function activityHasLockedMutex(activity : Activity)
    {

#if (cpp || neko || java)
        gMapLock.acquire();
#end

        var ret = gMap.exists(activity);

#if (cpp || neko || java)
        gMapLock.release();
#end

        return ret;
    }
#end

    private static var gMap : haxe.ds.ObjectMap<Activity, Array<Mutex>> =
        new haxe.ds.ObjectMap<Activity, Array<Mutex>>();

#if (cpp || neko || java)
    private static var gMapLock : SystemMutex = new SystemMutex();
    private var mSystemMutex : SystemMutex;
#end
}
