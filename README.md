

Introduction
============

The Activity API is designed to enable a cross-platform mechanism for allowing multiple contexts of execution (not called 'threads' here because they do not represent true threads) to co-exist within a single program.


Current State
-------------

For the current state of this haxelib, see STATUS.md in this repository.


Conceptual Introduction
-----------------------

This library was presented for consideration publically at WWX 2015.  That presentation discusses the motivations for developing the activity haxelib as well as the conceptual framework it embodies.  The presentation is available:

  https://github.com/kulick/wwx2015/blob/master/WWX2015_ActivityHaxelib.pdf


What is an Activity?
--------------------

An Activity is a concept similar to, but not identical to, a thread:

- Like a thread, an Activity is a context of execution - it represents the execution of program statements that follow in logical order, one after the other, and that can be executed completely independently of the statements executed by any other context of execution.

- Unlike a thread, an Activity is defined not by a single function that, upon exit, terminates the thread, but instead by a continuous serious of functions, each being scheduled to run some time after the currently executing function.  So a thread is the execution of a single function, whereas an Activity is the execution of one or more functions in sequence.

- The 'lifetime' of an Activity spans possibly many functions, but only one function is executed within an Activity at a time.

- Some platforms may run multiple Activities concurrently, or may only be able to run one Activity at a time ("running an Activity" means to execute a function in the context of that Activity).  In either case, all of the functions for all Activities will eventually be executed.

- Because Activities may be run in a single threaded program, Activities cannot assume that blocking in one Activity will still allow other Activities to run.  For this reason, Activities must never block indefinitely, and should limit the execution time of any particular function to the smallest time possible.

- Activities do not have the same locking and execution control primitives that threads do.  Thread locking/execution control primitives typically include mutexes, semaphores, and, sometimes, condition variables.  Activities cannot use semaphores or condition variables, because these imply the 'blocking' of an Activity, which, as mentioned in the previous bullet point, is not allowed.  Activities can use a special form of mutex which must never be held beyond the scope of any Activity function call, which allows protection of resources shared between Activities from concurrent access as long as the protected section is entirely contained within one Activity function call.  There is no other execution exclusion primitive for Activities, so Activities must be designed to work much more independently than can potentially be implemented for Threads.

- Similar to a thread, Activities all exist within the same address space and have access to all of the same global variables and any variables shared between Activities via Activity constructor parameters.  However, because Activities do not support rich locking primitives, data shared between threads must be used very carefully.  To facilitate safe sharing of data between threads, a message queue class is provided.

- An Activity can be "terminated" by calling shutdown() on it.  This will prevent any further callbacks from being made on the Activity, and will automatically shut down certain resources associated with Activities (such as Socket listeners).


Platform Implementation
-----------------------

The API is designed so as to be amenable to implementation on three broad platform "flavors":

- Single threaded platforms that "control the main loop".  These are platforms that are expected to run entirely from within the main() function of the main class, but can only use a single thread of execution.  The Activity implementation on such platforms runs a loop directly within the main function of the program to execute all outstanding Activity functions.  Examples are Python and PHP.

- Multi threaded platforms that "control the main loop".  These are similar to single threaded platforms that control the main loop, with the difference being that multi threaded platforms are expected to create multiple threads to run multiple Activities in parallel for better performance.  Examples are C++ and Java.

- Single threaded platforms that do not "control the main loop".  These platforms merely set up their actions in their main function and then exit the main function, continuing to execute via timers and other callbacks from the runtime itself.  Examples are Javascript and Flash.



The API
=======


Activity
--------

The Activity class is the main class of the API.  All Haxe programs that use the Activity API should set up their main function more or less as follows:

```
static function main()
{
   // ... do any stuff not related to Activities ...

   // create one (or more) Activities
   Activity.create(mainActivityFunction, "main");

   // run activities
   Activity.run();

   // ... typically, do nothing more; any code executed here cannot rely
   // on Activities having all completed already, having not even started yet,
   // or currently being in progress.
}
```


To create a new Activity, which is a context of execution that can run functions independently of any other Activities, and possibly in parallel with them, use Activity.create().  This function takes a closure to run as the first function run within the Activity, and an optional name of that Activity, to be used during Activity diagnostics.

The main function of an Activity might do all of the work that the Activity will ever need to do, but typically it will not; typically it will create an object to manage the "state" of the code associated with the Activity, and set up any event sources such as Sockets and Timers that the Activity will use, and possibly schedule additional work to be done via subsequent Activity function calls.

Note that all functions ever registered to be called in an Activity, including the main function specified for the Activity, are always called within the context of the Activity.  For example, a more concise way to start an Activity associated with a single object is:

```
static function main()
{
    var messageQueue = new MessageQueue<String>();

    Activity.create(function () { new MyActivity(messageQueue); }, "main");
    
    messageQueue.sender.send("Hello, world!");

	Activity.run();
}

class MyActivity
{
   public function new(mq : MessageQueue)
   {
       // note that this constructor is guaranteed to be called in the
       // context of the activity created by the call to Activity.create(),
       // and any Activity API that is called here will be associated with
       // that Activity

	   // Create a socket, connect it, and set up onReadable() to be called
       // when the Socket is readable and onWritable() to be called when the
       // Socket is writable
       mSocket = new Socket();
	   mSocket.connect("127.0.0.1", 5678);
       mSocket.setReadable(this.onReadable);
       mSocket.setWritable(this.onWritable);

	   // Listen on mq for messages, just print them out for now
	   mq.receiver.receive = function (msg : String)
                             {
                                 trace("Received message: " + msg);
                             });

	   // Defer some more code to be run in the doMoreWork() function
	   CallMe.soon(this.doMoreWork);

	   // Defer some code to be run when there is nothing else to be run
	   CallMe.later(this.doIdleStuff);

       // Schedule a call to run after 5 seconds
       Timer.once(this.onTimer, 5.0);
    }
}
```

Mutex
-----

This class is meant to be used to ensure that no two Activities enter a section of code at the same time.  Typically this is used to prevent simultaneous access to a shared data structure.  Mutex is a no-op on single threaded platforms (because it is not possible for two Activities to be running at the same time so no simultaneous access is possible), but is implemented on multi threaded platforms in the usual way.  Note that any Mutex that is locked within an Activity function call *must* be unlocked before that function returns.


NotificationQueue
-----------------

NotificationQueue provides a NotificationSender and NotificationReceiver that can be used to allow one Activity to notify another Activity when some condition has occurred.  Typically, a single Activity would use the NotificationReceiver to receive notifications, but multiple Activities can register to receive notifications for a single NotificationQueue; in this case, each notification will be received by one of these Activities (not all of them).

NotificationQueue tries to be "smart" in which Activity it chooses to schedule the listener callback on every time a notification is sent: it attempts to choose an Activity that is not otherwise busy, or expected to be busy soon, in order to try to allow the most work to be done in parallel as possible on multi-threaded systems.


MessageQueue
------------

MessageQueue provides a MessageSender and MessageReceiver that can be used to allow one Activity to send messages to another Activity or set of Activities.  If multiple Activities have registered to receive messages for a single MessageQueue; in this case, each message will be received by one of these Activities (not all of them).

MessageQueue tries to be "smart" in which Activity it chooses to schedule the listener callback on every time a message is sent: it attempts to choose an Activity that is not otherwise busy, or expected to be busy soon, in order to try to allow the most work to be done in parallel as possible on multi-threaded systems.

Note that a MessageQueue can send any type of value from one Activity to another, which means that Activities must be careful when sharing objects, to ensure that concurrent access is not possible (using Mutex locking, or even better, using "pass by value" mechanisms).


Socket
------

Provides a similar API to sys.net.Socket, except that works within the Activity framework (and does not provide select(), as this functionality is implemented as an intrinsic part of the Activity system).  Activities can set a function to be called on the Activity when the Socket is readable and when it is writable.  Sockets support blocking even though this is generally not acceptable for use within the Activity API, so in general, the functions that enable blocking Socket operations should not be used.

Socket is only available on, and supported on, platforms that implement sys.net.Socket.


XMLSocket
---------


Not defined yet, but will provide a similar API to Socket, suitably reduced and massaged to conform to the XMLSocket API present in Javascript and Flash.  Will be implemented on all platforms.


WebSocket
---------

Implements an API very similar to the JavaScript "WebSockets" API.  This allows only client based socket connections, and is the only networking mechanism supported on all target platform types.


WorkerPool
----------

Manages a pool of worker Activities that can do work concurrently on multithreaded platforms.  Example of use:

```
// Example work unit.  This work unit has both an input and an output, but
// some worker pools may not have any output.
typedef WorkUnit = { input : Float, output : Float };

class WorkerPoolExample
{
    public static function main()
    {
        var workerPool = new WorkerPoolExample();

        Activity.create(function () { workerPool.run(0.0, 100000, 0.05) });

        Activity.create(function () { workerPool.run(100000, 100000, -0.05) });

        // Note that nothing happens unless Activity.run() is run.  Normally
        // there would be a master Activity created for the program that would
        // be the one creating the worker pools an other Activities.
        Activity.run();
    }

    public function new()
    {
        mWorkerPool = new WorkerPool<WorkUnit>
            (10, this.doWork, "worker pool example");
    }

    public function run(start : Float, iterations : Int, step : Float)
    {
        for (i in 0 ... iterations) {
            var unit : WorkUnit = { start, 0 };
            mWorkerPool.work(unit,
                             function ()
                             {
                                 Sys.println("Ln of " + unit.input + " is " +
                                             unit.output);
                             });
            start += step;
        }
    }

    private function doWork(unit : WorkUnit)
    {
        // Compute Math.log(input), save to output
        unit.output = Math.log(unit.input);
    }

    private var mWorkerPool : WorkerPool<WorkUnit>;
}
```


Scheduling
==========

The Activity API provides direct scheduling via the "CallMe" class, and it knows about three general types of scheduled functions:

- Immediately : any function scheduled to be run immediately on an Activity (via CallMe.immediately()) will run as the very next function called in the Activity, regardless of what else has been scheduled.  Thus such functions run before expired timers, socket ready callbacks, and any other call.  Only a function subsequently submitted via another call to CallMe.immediately() will run first.

- Normal : includes functions scheduled 'soon' (via CallMe.soon()) in addition to socket and timer callbacks.  All normal functions execute after all immediate functions, and before all later functions.

- Later : any function scheduled to be run later (via CallMe.later()) will only be run when there is no other function to be run on the Activity (i.e. the Activity has completely quiesced, including polling any sockets associated with the activity).  "Idle functions" can be implemented via CallMe.later()

Within the Normal category of calls, we have:

- Expired timer callbacks.  These take highest precendence and are always called before any other callbacks in the normal category.  This is to ensure the timeliest possible timer callbacks.
  
- Socket ready callbacks.  These happen after any expired timer callbacks, but before any calls scheduled via CallMe.soon().  The idea is to allow the servicing of socket data with the lower latency than would be achieved if socket ready callbacks were handled after "soon" callbacks (the socket ready callback handler can always just schedule a "soon" callback if it doesn't care about handling socket data in the timeliest fashion but instead would want other work to take precedence).

- "Soon" calls : scheduled via calls to CallMe.soon().  These are executed when there are no more expired timer or socket ready callbacks to be made in the "Normal" segment of the callback list, and are made in the order of the calls CallMe Activity.soon().


Cancelling Work
===============

Every time any function call is scheduled, the caller may optionally request that an Id be returned that can be used to cancel that call later (if it hasn't happened yet) by passing 'true' in for the 'cancellable' argument.  However, doing so uses slightly more system resources than not requesting cancellability, so the default cancellability for soon(), immediate(), and later() is false, because it is not expected that cancelling these types of scheduled calls will be the norm.  However, the default for timer() is to return a CancelId, because timers are generally expected to need to be cancellable.


Shutting Down
=============

Activities may call Activity.shutdown(), which completely shuts down the calling Activity and all of the Activities that it has created (and all of the Activities that those Activities have created, recursively) - after the function which called Activity.shutdown() finishes, no more callbacks will ever be made on these Activities (including socket callbacks), and furthermore, subsequent attempts to schedule work on these Activities will result in ActivityError.Shutdown exceptions to be thrown.

Note that the NotificationQueue and MessageQueue classes internally handle detecting when Activities that were registered to receive events have been shut down, and will automatically remove those Activities as listeners when they are detected.  However, this does mean that until a message is sent on each NotificationQueue/MessageQueue that the shut down Activity was listening on, a reference to that Activity will still be held by that Queue.  If it is important that the Activity is garbage collected immediately, the Activity can manually unlisten to its Queues before shutting down.
