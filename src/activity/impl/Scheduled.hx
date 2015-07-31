/** *************************************************************************
 * Scheduled.hx
 *
 * Copyright 2014 TiVo, Inc.
 ************************************************************************** **/

package activity.impl;

import activity.Activity;
#if cpp
import cpp.vm.Mutex;
#elseif neko
import neko.vm.Mutex;
#elseif java
import java.vm.Mutex;
#end


/**
 * The Scheduled class represents a scheduled callme or scheduled timer.
 * Scheduled objects are pooled so as to reduce churn.
 **/

class Scheduled
{
    public var cancelId(default, null) : CancelId;
    public var activity(default, null) : Activity;
    // The following could be handled by an enum, but enums churn, and to
    // avoid that, don't use an enum
    public var f_callme(default, null) : Void -> Void;      // only for callme
    public var onShutdown(default, null) : Void -> Void;    // only for callme
    public var f_timer(default, null) : Float -> Void;      // only for timer
    public var when(default, null) : Float;                 // only for timer
    // The prev and next references put the Scheduled object on up to one
    // FastList
    public var prev : Null<Scheduled>;
    public var next : Null<Scheduled>;

    // Use pooling to reduce churn on these very frequently allocated objects
    public static function acquire_callme(activity : Activity,
                                          cancellable : Bool,
                                          f : Void -> Void,
                                          onShutdown : Void -> Void) : Scheduled
    {
        var ret = acquire(activity, cancellable);
        ret.f_callme = f;
        ret.onShutdown = onShutdown;
        return ret;
    }

    public static function acquire_timer(activity : Activity,
                                         cancellable : Bool,
                                         f : Float -> Void,
                                         when : Float) : Scheduled
    {
        var ret = acquire(activity, cancellable);
        ret.f_timer = f;
        ret.when = when;
        return ret;
    }

    public static function cancel(cancelId : CancelId)
    {
#if (cpp || neko || java)
        gCancelMapMutex.acquire();
#end
        var s = gCancelMap.get(cancelId);

        if (s == null) {
#if (cpp || neko || java)
            gCancelMapMutex.release();
#end
            return;
        }

#if (cpp || neko || java)
        s.mMutex.acquire();
        gCancelMapMutex.release();
#end

        s.f_callme = null;
        s.f_timer = null;
        s.when = 0;

#if (cpp || neko || java)
        s.mMutex.release();
#end
    }

    public function run()
    {
#if (cpp || neko || java)
        mMutex.acquire();
#end

        // If the scheduled callback had a timer function in f_timer, then
        // it was a scheduled timer callback and needs to be called with
        // the "number of seconds past the scheduled timeout that this
        // callback is occurring"
        if (this.f_timer != null) {
            this.f_timer(haxe.Timer.stamp() - this.when);
        }
        // Else the scheduled callback must have a normal call me function
        // in f_callme, which is called with no arguments
        else if (this.f_callme != null) {
            this.f_callme();
        }
        // Else, both the timer and callme callback functions were null,
        // which is true if the scheduled object was already cancelled
        
#if (cpp || neko || java)
        mMutex.release();
#end
    }

    public static function release(s : Scheduled)
    {
        if (s.cancelId != null) {
#if (cpp || neko || java)
            gCancelMapMutex.acquire();
#end
            gCancelMap.remove(s.cancelId);
#if (cpp || neko || java)
            gCancelMapMutex.release();
#end
            s.cancelId = null;
        }
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
#if (cpp || neko || java)
        mMutex = new Mutex();
#end
    }

    private static inline function acquire(activity : Activity,
                                           cancellable : Bool)
    {
        var ret : Scheduled;

#if (cpp || neko || java)
        ret = gPool.pop(false);
#else
        ret = gPool.pop();
#end
        if (ret == null) {
            ret = new Scheduled();
        }

        if (cancellable) {
            ret.cancelId = { };
#if (cpp || neko || java)
            gCancelMapMutex.acquire();
#end
            gCancelMap.set(ret.cancelId, ret);
#if (cpp || neko || java)
            gCancelMapMutex.release();
#end
        }

        ret.activity = activity;

        return ret;
    }

#if cpp
    private static var gPool : cpp.vm.Deque<Scheduled> =
        new cpp.vm.Deque<Scheduled>();
#elseif neko
    private static var gPool : neko.vm.Deque<Scheduled> =
        new neko.vm.Deque<Scheduled>();
#elseif java
    private static var gPool : java.vm.Deque<Scheduled> =
        new java.vm.Deque<Scheduled>();
#else
    private static var gPool : Array<Scheduled> = [ ];
#end

    // Mapping of cancel ids to the Scheduled that they cancel
    private static var gCancelMap : haxe.ds.ObjectMap<CancelId, Scheduled> =
        new haxe.ds.ObjectMap<CancelId, Scheduled>();
#if (cpp || neko || java)
    private static var gCancelMapMutex : Mutex = new Mutex();
    private var mMutex : Mutex;
#end
}
