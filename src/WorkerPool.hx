/** *************************************************************************
 * WorkerPool.hx
 *
 * Copyright 2014 TiVo, Inc.
 ************************************************************************** **/

package activity;

import activity.MessageQueue;
import activity.impl.Scheduler;

/**
 * WorkerPool is a utility class that can manage a pool of "worker"
 * Activities.  On single threaded platforms, the work is done sequentially,
 * but on multi threaded platforms, work may be done concurrently by multiple
 * threads and thus may utilize all processors known to the runtime.
 *
 * The parameter T defines the type of the value passed to the work function,
 * thus specifying the 'work input'.
 *
 * The parameter U defines the type of the value returned from the work
 * function, and passed to the optional completion function, thus specifying
 * the 'work output'.
 **/
class WorkerPool<T, U>
{
    /**
     * Creates a new worker pool.  This pool will run the given work function
     * any time work is added to the pool.  The Activity which performs the
     * work is chosen by the worker pool, which may make multiple concurrent
     * calls to execute work that is scheduled simultaneously (on multi
     * threaded platforms).
     *
     * @param poolSize is the maximum number of Activities to use to execute
     *        work.
     * @param workFunction is the closure that will be called whenever a work
     *        item is to be processed by the worker pool.  It must process its
     *        input value of type T and return an output value of type U.  The
     *        Activity in which this work function is executed is an arbitrary
     *        Activity owned by the worker pool.  Note that the work function
     *        may be called simultaneously by multiple threads, so it must be
     *        careful when accessing values within its closure that may be
     *        simultaneously accessed by other calls into the same closure.
     * @param name is an optional name to be given to the worker pool; all
     *        worker pool Activities will use a name derived from this name.
     **/
    public function new(poolSize : Int, workFunction : T -> U,
                        name : String = null)
    {
        mQ = new MessageQueue<WorkerPoolUnit<T, U>>();
        mF = workFunction;
        // Minor efficiency improvement: create one closure, not poolSize
        // closures
        var workActivityMain =
        function ()
        {
            mQ.receiver.receive = this.doWork;
        };
        for (i in 0 ... poolSize) {
            Activity.create(workActivityMain, null, getWorkerName(name, i));
        }
    }

    /**
     * Perform the work function of the WorkerPool on the input value T,
     * calling the completion function (if provided) when the work is
     * complete.  The completion function is called in the same Activity that
     * called work().
     *
     * If the work produces a result, that result should be stored in a field
     * of the input data structure.  For example:
     *
     * typedef WorkItem = { in : Int, out : Int };
     *
     * This defines a work item that has an input value (in) and can store
     * the result of doing the work in an output value (out).
     *
     * function myWorkFunction (item : WorkItem)
     * {
     *    item.out = item.in + 1;
     * }
     *
     * This defines a work function that takes the input Int, adds 1, and
     * stores the result in the output Int.
     *
     * var workItem : WorkItem = { in : 10, out : 0 };
     * workerPool.work(workItem,
     *                 function ()
     *                 {
     *                     trace(workItem.in + " plus one is " + workItem.out);
     *                 });
     *
     * The above causes the work function to be run on the workItem, and when
     * complete, the output is printed.
     *
     * @param input is the input data to work on.  This data will be passed to
     *        the workFunction that was provided in the WorkerPool
     *        constructor, which will be run in an arbitrary Activity of the
     *        WorkerPool
     * @param completion is a closure to be called *in the Activity that
     *        called work()* when the workFunction has completed.  It is
     *        passed [input] and the result of the work function when called
     *        on that input as arguments.  Note that the completion function
     *        is not cancellable.
     **/
    public function work(input : T, completion : T -> U -> Void = null)
    {
        mQ.send({ input : input,
                  activity : ((completion == null) ?
                              null : Scheduler.getCurrentActivity()),
                  completion : completion });
    }


    // ------------------------------------------------------------------------
    // Private implementation follows -- please ignore.
    // ------------------------------------------------------------------------

    private function doWork(u : WorkerPoolUnit)
    {
        var result = mF(u.input);
        if (u.completion != null) {
            try {
                // No one to report the cancel id to, so the completion
                // function cannot be cancelled
                Scheduler.soon(u.activity, function ()
                                           {
                                               u.completion(u.input, result);
                                           });
            }
            catch (e : ActivityError.Shutdown) {
                // The work output is lost because the Activity that would
                // receive it has been shut down
            }
        }
    }

    private static function getWorkerName(baseName : String,
                                          index : Int) : String
    {
        return (((baseName == null) ? 
                 "anonymous worker pool" : baseName) + " worker " + index);
    }

    private var mQ : MessageQueue<WorkerPoolUnit<T, U>>;
    private var mF : T -> U;
}

private typedef WorkerPoolUnit<T, U> = { input : T,
                                         activity : Activity,
                                         completion : T -> U -> Void };
