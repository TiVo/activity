/** *************************************************************************
 * Scheduler.hx
 *
 * Copyright 2014 TiVo, Inc.
 ************************************************************************** **/

package activity.impl;

// cpp, neko, cs, and java targets support threading
#if (cpp || neko || cs || java)
// Not quite ready for prime time yet; depends upon custom changes to haxe/hxcpp.
//typedef Scheduler = activity.impl.MultiThreadedScheduler;
typedef Scheduler = activity.impl.SingleThreadedScheduler;
// js and flash targets do not control the main loop and must use timers
#elseif (js || flash || flash8)
typedef Scheduler = activity.impl.TimerScheduler;
// php and python targets run a single threaded main loop
#elseif (php || python)
typedef Scheduler = activity.impl.SingleThreadedScheduler;
#else
#error Scheduler has not been ported to this platform!
#end

// Order of event delivery:
// - Immediate -- always called next if one is pending
// - Normal -- called if there is no Immediate, before all Later
//   - Timer -- called within the 'Normal' range as soon as it expires
//              (before other Normal calls)
//   - Socket -- called within the 'Normal' range as soon as socket
//               readability/writability is detected (which may be any time,
//               and is called after expired Timers but before other Soon
//               calls)
//   - Soon
// - Later -- always called only when there is nothing else pending

#if 0 /// documentation of API
class Scheduler
{
    public static function getCurrentActivity() : Activity;

    public static function create(uncaught : Dynamic -> Void,
                                  name : String);

    public static function run(completion : Void -> Void);

    public static function immediately(f : Void -> Void,
                                       cancellable : Bool) : CancelId;

    public static function soon(activity : Activity,
                                f : Void -> Void,
                                onShutdown : Void -> Void,
                                cancellable : Bool) : CancelId;

    public static function later(f : Void -> Void,
                                 cancellable : Bool) : CancelId;

    public static function timer(f : Float -> Void, timeout : Float,
                                 cancellable : Bool) : CancelId;

    public static function cancel(cancelId : CancelId);

    public static function shutdown();

    // Be aware that the activity chosen may have been evicted already, or may
    // be evicted at any time after it has been returned from choose().
    // This highlights the fact that on multithreaded systems there is a
    // latency between the return from this function, and any subsequent
    // scheduling operation that could be done, that may make the returned
    // Activity *not* be the ideal candidate at the time that the schedule
    // call is actually made.  The latency is likely to be so small though as
    // to not be worth even worrying about.
    public static function choose(activities : Iterator<Activity>) : Activity;

    // Socket support on platforms that support sys.net.Socket

#if (cpp || cs || java || neko || php || python)

    // While running Normal and Later calls, attempts are made to poll
    // sockets at least this often, in milliseconds.  Default is 100 ms.
    // Passing in < 0 uses default.  Passing in 0 causes a guaranteed poll
    // after every Normal and Later call.
    public static function setSocketPollInterval(seconds : Float);

    // Passing in null stops a previously registered function from being
    // called for that Socket
    public static function socketReadable(f : Void -> Void,
                                          socket : sys.net.Socket);

    // Passing in null stops a previously registered function from being
    // called for that Socket
    public static function socketWritable(f : Void -> Void,
                                          socket : sys.net.Socket);

#end // cpp || cs || java || neko || php || python

    // XMLSocket support -- all platforms

}
#end
