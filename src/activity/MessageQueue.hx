/** *************************************************************************
 * MessageQueue.hx
 *
 * Copyright 2014 TiVo, Inc.
 ************************************************************************** **/

package activity;

import activity.Activity;
import activity.MessageReceiver;
import activity.MessageSender;
import activity.impl.Scheduler;

/**
 * MessageQueue is used to deliver messages from one Activity to any number of
 * receiving Activities.  The Activity which will receive any given message is
 * arbitrary, although MessageQueue attempts to choose the "least busy"
 * Activity at the time that a message is put into the message queue.
 *
 * This is the only mechanism officially supported for exchanging values
 * between two Activities.  Because Activity objects should never hold
 * references to other Activity objects, MessageQueues should be created and
 * used by Activity objects as a means for exchanging information between
 * Activities.  Typically, one Activity will hold the sending endpoint of the
 * MessageQueue, and a different Activity will hold the receiving endpoint of
 * the MessageQueue, and these endpoints will have been provided to the
 * Activities by the code that created the Activities.
 *
 * Note that although messages are scheduled for delivery in the same order
 * that they were sent, the timing of the receipt of messages (embodied by the
 * call into a registered Activity with the message) is up to the activity
 * scheduler and may choose to run these callbacks in a different order than
 * the message sends actually occurred.  However, if there is only a single
 * receiver of messages, then it will receive the messages in the same order
 * they were sent.
 *
 * Note also that any Activity which is shutdown while it is an active
 * receiver of messages on a MessageQueue may end up "swallowing" messages
 * that were queued for delivery to that Activity.  In this way, messages can
 * be lost from the queue if receivers shut down while actively listening to
 * the queue.  However, if an Activity sets its receiver to null for a
 * MessageQueue, no messages will ever be lost in this way for that Activity.
 **/
class MessageQueue<T>
{
    /**
     * The sender property is the MessageSender that can be used by any
     * context of execution - Activity or not - to send messages to one of the
     * Activities registered with the MessageReceiver.  The Activity that
     * receives the message is chosen to be the one predicted to be able to
     * handle the message the soonest.
     **/
    public var sender(default, null) : MessageSender<T>;
    /**
     * The receiver property is the MessageReceiver that can be used to set a
     * call to be made in the calling Activity when sender.send() has been
     * called.  If the MessageQueue was created with the singleReceiver
     * parameter as true, then setting the receiver will automatically remove
     * any prior receivers.  If the MessageQueue was created with the
     * singleReceiver parameter as false (which is the default), each Activity
     * independently adds and removes itself from the receiver.
     **/
    public var receiver(default, null) : MessageReceiver<T>;

    /**
     * Creates a new empty MessageQueue.
     *
     * @param singleReceiver if true, the message queue will deliver messages
     *        to only a single Activity at a time (any Activity setting
     *        receiver.receive will overwrite any Activity which set it
     *        previously).  If singleReceiver if false (the default), the
     *        message queue will deliver to multiple Activities.
     **/
    public function new(singleReceiver : Bool = false)
    {
        this.sender = new MessageSender<T>(this);
        this.receiver = new MessageReceiver<T>(this);
        mSingleReceiver = singleReceiver;
        mLock = new Mutex();
        mQueue = new List<T>();
        mNotificationCount = 0;
        mListeners = new haxe.ds.ObjectMap<Activity, T -> Void>();
        mListenerCount = 0;
        mResendClosure = this.resend;
        mCallbackClosure = this.callback;
    }


    // ------------------------------------------------------------------------
    // Private implementation follows -- please ignore.
    // ------------------------------------------------------------------------

    @:allow(activity.MessageSender)
    private function send(msg : T)
    {
        mLock.lock();
        mQueue.add(msg);
        mNotificationCount += 1;
        this.scheduleCallbacksLocked();
        mLock.unlock();
    }

    @:allow(activity.MessageSender)
    private function clear()
    {
        mLock.lock();
        mQueue.clear();
        mNotificationCount = 0;
        mLock.unlock();
    }

    @:allow(activity.MessageReceiver)
    private function setCurrentActivityReceive(f : T -> Void)
    {
        var currentActivity = Scheduler.getCurrentActivity();
#if AUDIT_ACTIVITIES
        if (currentActivity == null) {
            throw "Must set MessageReceiver.receive from within an activity";
        }
#end
        mLock.lock();
        if (mSingleReceiver) {
            if (mListenerCount > 0) {
                mListeners = new haxe.ds.ObjectMap<Activity, T -> Void>();
                mListenerCount = 0;
            }
        }
        else if (mListeners.exists(currentActivity)) {
            mListeners.remove(currentActivity);
            mListenerCount -= 1;
        }
        if (f != null) {
            mListeners.set(currentActivity, f);
            // If this is the first Activity to add a listener, then schedule
            // a call for each deferred message
            if (++mListenerCount == 1) {
                this.scheduleCallbacksLocked();
            }
        }
        mLock.unlock();
        return f;
    }

    private function scheduleCallbacksLocked()
    {
        // Keep trying to find an activity object to notify which has not yet
        // been shut down
        while ((mListenerCount > 0) && (mNotificationCount > 0)) {
            var chosen = Scheduler.choose(mListeners.keys());
            try {
                Scheduler.soon(chosen, mCallbackClosure, mResendClosure, false);
                mNotificationCount -= 1;
                return;
            }
            catch (e : activity.ActivityError) {
                switch (e) {
                case Shutdown:
                    // Remove the shut down activity from the listeners, and
                    // continue the loop
                    mListeners.remove(chosen);
                    mListenerCount -= 1;
                case MutexStillLocked:
                    throw e;
                }
            }
        }
    }

    private function resend()
    {
        mLock.lock();
        mNotificationCount += 1;
        this.scheduleCallbacksLocked();
        mLock.unlock();
    }

    private function callback()
    {
        mLock.lock();
        var f = mListeners.get(Scheduler.getCurrentActivity());
        if (f == null) {
            // Listener already removed, so activity a callback on a different
            // Activity
            mNotificationCount += 1;
            this.scheduleCallbacksLocked();
            mLock.unlock();
        }
        else {
            var v = mQueue.pop();
            mLock.unlock();
            f(v);
        }
    }

    private var mSingleReceiver : Bool;
    private var mLock : Mutex;
    private var mQueue : List<T>;
    private var mNotificationCount : Int;
    private var mListeners : haxe.ds.ObjectMap<Activity, T -> Void>;
    private var mListenerCount : Int;
    private var mResendClosure : Void -> Void;
    private var mCallbackClosure : Void -> Void;
}
