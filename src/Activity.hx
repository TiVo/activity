/** *************************************************************************
 * Activity.hx
 *
 * Copyright 2014 TiVo, Inc.
 ************************************************************************** **/

package activity;

import activity.impl.Scheduler;

/**
 * Type of the identifier of a scheduled callback, that can be used to cancel
 * that callback.
 **/
typedef CancelId = { };


/**
 * Errors that can be thrown from Activity functions
 **/
enum ActivityError
{
    /**
     * This value is thrown when an attempt is made to schedule a call on an
     * Activity object that has already been shut down.
     **/
    Shutdown;
    /**
     * This value is thrown only when AUDIT_ACTIVITY has been defined, and is
     * thrown when a call on an Activity has returned with a Mutex still
     * locked
     **/
    MutexStillLocked;
}


/**
 * The Activity class represents a single context of execution wherein
 * multiple function closures may be scheduled for execution.  The important
 * aspects of an activity instance are that only one function closure at a
 * time will be run within that Activity instance, regardless of how many
 * function closures have been scheduled to be run.  Therefore, an Activity
 * represents something akin to a single thread in multithreaded programming,
 * with the caveat that the actual system thread that runs any particular
 * function call within a single Activity is not guaranteed to be the same
 * between such calls.  And depending upon the platform in which the Activity
 * API is used, there may or may not be multiple Activity functions (on
 * different Activity instances) being run concurrently.
 **/
class Activity
{
    /**
     * This property may only be accessed within a scheduled function call,
     * which is the only time that there is such a thing as "this Activity".
     * This value gives a unique String identifier for the current Activity.
     * If the caller is not running with an Activity, this value is null.
     **/
    public static var thisID(get_thisID, null) : String;

    /**
     * This property may only be accessed within a scheduled function call,
     * which is the only time that there is such a thing as "this Activity".
     * This value gives whatever name was given to the Activity by the
     * create() function. If the caller is not running with an Activity, this
     * value is null.
     **/
    public static var thisName(get_thisName, null) : String;
    
    /**
     * Schedules a function to be run in a new Activity.  A typical usage
     * would be for f to create an object that runs within its own Activity.
     * Note that f is not called immediately, it is deferred to run as the
     * first call of a newly created Activity.
     *
     * If the context of execution which makes this call is within an
     * Activity, then the created Activity is a child of the calling Activity
     * and will be shut down when the calling Activity is shut down.
     *
     * @param f is the first function to be run in the newly created
     *        Activity.  Must not be null.
     * @param uncaught is an optional function closure to be run when an
     *        exception is thrown from a scheduled function call for the
     *        Activity.  The Activity that threw the uncaught exception will
     *        already have been shut down when this function is called.  The
     *        argument passed to the uncaught function is the uncaught
     *        exception.  If the 'uncaught' function throws an exception, it
     *        will not be caught by the Scheduler framework.
     * @param name is an optional parameter which provides a name for the
     *        Activity.  This name is then available from within the Activity
     *        itself via the 'thisName' property.  Note that a unique
     *        (although not particularly readable) identifer for the Activity
     *        object is available from the 'thisID' property of the Activity
     *        within the Activity itself.
     **/
    public static function create(f : Void -> Void,
                                  uncaught : Dynamic -> Void = null,
                                  name : String = "")
    {
        Scheduler.soon(Scheduler.create(uncaught, name), f, null, false);
    }

    /**
     * Ensures that all created Activities are run; on platforms which control
     * the 'main loop', this will run all Activities to completion.  On
     * platforms which do not, this will do nothing, but all Activities will
     * have been set up to be run by the main loop.  Note that until this
     * function is called, no previously created Activities will be run.  Note
     * also that this function may not be called from more than one thread in
     * the calling program at once.
     *
     * @param completion is an optional function closure to be run when all
     *        Activities that were created have completed, which means that
     *        there is no more work to be done within any Activity.  Note
     *        that the completion function may be called before or after run()
     *        returns, and from an arbitrary thread that may or may not be the
     *        calling thread.
     **/
    public static function run(completion : Void -> Void = null)
    {
        Scheduler.run(completion);
    }

    /**
     * Shuts down the calling Activity and all children of that Activity
     * (recursively) atomically, which:
     * - Prevents any scheduled calls from occurring
     * - Stops any calls from being scheduled on the Activity (any attempts
     *   to schedule throws an ActivityError.Shutdown exception)
     * - Stops listening for readable/writable on any Sockets for which this
     *   Activity has set a Socket.onReadable or Socket.onWritable property
     *
     * Additionally, on multithreaded systems, this call will wait until all
     * child Activities have completed all outstanding calls before returning.
     **/
    public static function shutdown()
    {
        Scheduler.shutdown();
    }


    // ------------------------------------------------------------------------
    // Private implementation follows -- please ignore.
    // ------------------------------------------------------------------------

    private static function get_thisID() : String
    {
        var currentActivity = Scheduler.getCurrentActivity();
        return (currentActivity == null) ? null : currentActivity.mID;
    }

    private static function get_thisName() : String
    {
        var currentActivity = Scheduler.getCurrentActivity();
        return (currentActivity == null) ? null : currentActivity.mName;
    }

    private function new(name : String)
    {
        var parentActivity = Scheduler.getCurrentActivity();
        mID = ((parentActivity == null) ?
               getNextMainID() :
               parentActivity.getNextChildID());
        mName = (name == null) ? "" : name;
        mNextChildActivityNumber = 0;
    }

    private function getNextChildID() : String
    {
        // No locking is needed.  Can only be called from create() called by
        // this Activity itself, and this Activity can only be run by one
        // thread at a time, therefore create() can only be called by a given
        // Activity by one thread at a time, therefore the member variables of
        // that Activity can only be used by one thread at a time.
        return mID + "." + mNextChildActivityNumber++;
    }

    private static function getNextMainID() : String
    {
        // No locking is needed.  Can only be called from create() called by a
        // non-Activity thread, and the contract for the Activity API says
        // that only one non-Activity thread is allowed to call create() at
        // once.  Therefore this code can only be called by one thread at a
        // time.
        return Std.string(gNextMainActivityNumber++);
    }

    // ID of this activity
    private var mID : String;
    // Name of this activity
    private var mName : String;
    // Next number to use in the ID of the next created child activity
    private var mNextChildActivityNumber : Int;

    // Next number to use in the ID of a main activity
    private static var gNextMainActivityNumber : Int = 0;
}
