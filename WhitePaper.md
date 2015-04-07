Copyright © 2015 TiVo Inc, Licensed under the Apache License, Version 2.0


Introducing the Activity Haxelib
================================

The activity haxelib is a haxe library whose purpose is to provide a thread-like mechanism for haxe programs that is supported for all haxe targets.  Programs written to use the activity haxelib will run using multiple system threads to enable best performance on multithread-capable targets, but will fall back to single threaded operation on multithread-incapable targets.

There are several advantages to using the activity haxelib over explicit multithreaded code:

* Programs written using the activity haxelib will run unaltered on all targets - no target-specific code necessary (i.e. no "#if cpp create a thread #else don't #end logic or similar)
* The activity haxelib provides a means for unrelated haxe libraries that would otherwise be unable to interoperate (due to all requiring control of the "main loop") to be used together.
* The mechanisms provided for inter-activity communication in the activity haxelib is a richer set than is available using system threads.  For example, the activity haxelib provides a worker pool for easily managing background work, whereas the system thread APIs provide no such mechanism (you'd have to roll your own).


What is an "Activity"?
======================

An activity is similar to a thread, but different in some important ways.  A traditional thread runs a single function to conclusion and then terminates, and is expected to be scheduled to run by the operating system in a time-sliced manner with other threads.  A thread can assume complete uninterrupted control over its context of execution, and yet the operating system (or virtual machine) allows multiple threads to be executed simultaneously.

Activities must be coded to be explicitly aware of the fact that they cannot assume complete control of their execution environment, and so must perform work in incremental steps which can be interleaved.  In other words, whereas a true thread runs a single function to completion, an activity spans many function calls, each of which must operate for a short enough time interval that no activity which has a function scheduled to be called on it is made to wait too long.  On a multithread-capable system, the individual short-lived activity function calls are scheduled on multiple system threads concurrently, allowing for concurrent execution and faster performace, but these functions, by their nature of having been coded to adhere to the activity API, can also be scheduled sequentially on a multithread-incapable system.

Activities are well suited to event-driven programming methodologies, where the asynchronous delivery of an event (such as a network packet, user input, or a timer) causes a small amount of work to be done to process the event, at which time control can be returned to the activity system, possibly with follow-on work scheduled for a subequent callback.  Work of longer duration is more difficult to adapt to the activity model, but can still be adapted if the work can be broken up into discrete chunks.



How are Activities Created and Used?
====================================

Activities are not represented by user-addressable objects.  Instead, an Activity is virtually represented as an accumulation of scheduled function callbacks that are to be run at some future time.  Any function call scheduled subsequently by those function calls becomes itself part of the activity.

An activity is created by calling the Activity.create() function, which will schedule a function to be called in the context of the newly created Activity.  Functions run in the context of an activity can schedule more work (as a simple callback scheduled to run as soon as possible, or as a timer scheduled to be called only at a given time), or set the Activity up to be the listener for one of several event sources: message queues, notification queues, and sockets.

There is no way to directly address an activity once it has been created, so typically all of the event sources that an activity will use will be set up before the activity is even created, so that the creator of the activity will have a means to communicate with it.  Because the activity system runs caller-provided function closures, and function closures can reference variables from the context in which they were created, child activities can share objects with the parent activity naturally just by referring to the same variable.

However, because activities may run concurrently on multi-threaded systems, it is imperative that activities only share objects that have been specifically designed to work within the activity system, such as MessageQueue, NotificationQueue, and Socket.  These objects may be created ahead of time by a parent Activity, and then passed to a child Activity (via function closure), as a means for communicating between parent and child.


How do Event Sources Work?
==========================

Event sources are objects that schedule function calls within an Activity in response to an event.  Examples of event sources are MessageQueue, NotificationQueue, Socket, and WebSocket.  Each of these objects allow the specification of closures to be called in an Activity when an event relevent to the event source occurs.  For example, when a message is pushed into a MessageQueue, the MessageQueue class schedules a function within an Activity registered to receive events from the MessageQueue which will be called with the message that was pushed in.  In this way, the sender can be one Activity, and the receiver is another Activity.  Similarly, Socket objects schedule closure calls on readable and writable events of the Socket.  Activities simply register closures to be called on events (in this case the closures can be described as "callbacks") and the activity scheduler ensures that as events occur, they are scheduled to be handled on the appropriate Activity.


What are the Threading/Locking Constraints on Activities?
=========================================================

On multi-thread-capable systems, activities will be run concurrently when possible, for best performance.  Because of this, all software written to use the activity haxelib should be aware of locking implications.  Activities themselves will only ever have one scheduled function call made within the Activity at a time, so as long as an Activity doesn't share any common data with another Activity, it can safely access and modify its own data without worrying about locking.  The event sources built into the activity haxelib (MessageQueue, NotificationQueue, Socket, etc) carry no extra locking concerns because they schedule functions to be called within Activities and thus do not introduce any concurrent execution of functions within an Activity.  The only time that locking is needed is if two Activities share a common data structure.  This data structure could be communicated between the Activities via closure scoped data that was available to both, or could be transmitted from one to another via a MessageQueue.  When there is shared data, Activities must use the Mutex class to prevent concurrent access by two Activities.  In general, using shared data is discouraged and should be avoided, because of the complexities involved in ensuring serialized access to this shared data, which is often a source of difficult to diagnose bugs in multi-threaded programs.  But if such sharing is unavoidable, then Mutex is provided to allow safe access by two Activities to the same data structure.  Note that a constraint of the activity haxelib Mutex is that it may only be locked during the duration of one Activity function call.  This is because holding a Mutex locked when an Activity function completes could cause a deadlock on single threaded systems when another Activity then tries to acquire the Mutex.  If you define the symbol AUDIT_ACTIVITY at compile time, then the activity scheduler will check to make sure that Mutex objects are not locked across Activity function calls and will throw an exception if one is, to assist in detecting programmatic errors.


How Can Activities Allow Broader Use and Sharing of Haxe-Based Projects?
========================================================================

There are some haxelibs and haxe programs that want to control the "main loop" (i.e. the main context of execution entered in the main() function and consisting of an event processing loop).  An example is the OpenFL haxelib, which generates a wrapper class that implements main() and in that implementation runs a loop that processes user input events, and periodically polls other event sources and performs frame rendering.

When a haxelib expects to not return control to a caller of one of its functions or otherwise takes control of the main loop, it cannot be used with another haxelib which expects to do the same thing.  The first haxelib would have to run its main loop to completion before the second haxelib would be given an opportunity to do the same.

However, if both haxelibs were built using the activity haxelib, then both would cooperatively allow the main loop to run without either explicitly knowing about the other.  Each would implement its functionality in small chunks that the activity system would interleave so as to allow both haxelibs to work at the same time.  Any number of haxelibs using the activity library could interoperate in this way.

Each haxelib would have to be written with a dependency on the activity haxelib, and each would likely provide a static function to initialize the haxelib, in which an activity would be created which would implement the functionality which previously would have been invoked from that haxelib's main loop.  The haxelib's initialization API would probably create the activity structures necessary to allow external code to interact with the haxelib; for example:

<pre>
function initializeLibrary() : MessageQueue<Message>
{
    var mq = new MessageQueue<Message>();
    new Activity(function () { setupLibraryToRunAndUseMessageQueue(mq); });
    return mq;
}
</pre>

This could be implemented by an activity-aware haxelib and would create a new MessageQueue<Message>, create a new Activity which has access to and acts as a writer into the message queue, and return the message queue which the caller of initializeLibrary() could then listen to to receive Message objects from the activity thus created.  The setupLibraryToRunAndUseMessageQueue function would run within the context of the newly created Activity and might do something like setting up a listener to receive messages on the given queue, with a handler function that actually processes the messages.

A second haxelib could be initialized in a similar manner, and its message handling callbacks would be interleaved with those of the first library on single threaded platforms, or run in parallel on multithreaded platforms.


Further Reading
===============

A more technical description of how the activity haxelib works, what its component pieces are, what features they have, and how they are used, is available as  README.md file in the activity haxelib itself.
