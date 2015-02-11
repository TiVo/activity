/** *************************************************************************
 * NotificationQueue.hx
 *
 * Copyright 2014 TiVo, Inc.
 ************************************************************************** **/

package activity;

import activity.Activity;
import activity.NotificationSender;
import activity.NotificationReceiver;
import activity.impl.Scheduler;

/**
 * NotificationQueue is used to deliver notifications from one Activity to any
 * number of receiving Activities.  The Activity which will receive any given
 * message is arbitrary, although NotificationQueue attempts to choose the
 * "least busy" Activity at the time that a message is put into the message
 * queue.
 *
 * Note also that any Activity which is shutdown while it is an active
 * receiver of notifications on a NotificationQueue may end up "swallowing"
 * notifications that were queued for delivery to that Activity.  In this way,
 * notifications can be lost from the queue if receivers shut down while
 * actively listening to the queue.  However, if an Activity sets its receiver
 * to null for a NotificationQueue, no notifications will ever be lost in this
 * way for that Activity.
 * 
 **/
class NotificationQueue
{
    /**
     * The sender property is the NotificationSender that can be used by any
     * Activity to send notifications to one of the Activities registered with
     * the NotificationReceiver.  The Activity that receives the notification
     * is chosen to be the one predicted to be able to handle the notification
     * the soonest.
     **/
    public var sender(default, null) : NotificationSender;
    /**
     * The receiver property is the NotificationReceiver that can be used to
     * set a call to be made in the calling Activity when sender.send() has
     * been called.  If the NotificationQueue was created with the
     * singleReceiver parameter as true, then setting the receiver will
     * automatically remove any prior receivers.  If the NotificationQueue was
     * created with the singleReceiver parameter as false (which is the
     * default), each Activity independently adds and removes itself from the
     * receiver.
     **/
    public var receiver(default, null) : NotificationReceiver;

    /**
     * Creates a new empty NotificationQueue.
     *
     * @param singleReceiver if true, the notification queue will deliver
     *        notifications to only a single Activity at a time (any Activity
     *        setting receiver.receive will overwrite any Activity which set
     *        it previously).  If singleReceiver if false (the default), the
     *        notification queue will deliver to multiple Activities.
     **/
    public function new(singleReceiver : Bool = false)
    {
        this.sender = new NotificationSender(this);
        this.receiver = new NotificationReceiver(this);
        mSingleReceiver = singleReceiver;
        mLock = new Mutex();
        mNotificationCount = 0;
        mListeners = new haxe.ds.ObjectMap<Activity, Void -> Void>();
        mListenerCount = 0;
        mResendClosure = this.resend;
        mCallbackClosure = this.callback;
    }


    // ------------------------------------------------------------------------
    // Private implementation follows -- please ignore.
    // ------------------------------------------------------------------------

    @:allow(activity.NotificationSender)
    private function send()
    {
        mLock.lock();
        mNotificationCount += 1;
        this.scheduleCallbacksLocked();
        mLock.unlock();
    }

    @:allow(activity.NotificationSender)
    private function clear()
    {
        mLock.lock();
        mNotificationCount = 0;
        mLock.unlock();
    }

    @:allow(activity.NotificationReceiver)
    private function setCurrentActivityReceive(f : Void -> Void)
    {
        var currentActivity = Scheduler.getCurrentActivity();
#if AUDIT_ACTIVITIES
        if (currentActivity == null) {
            throw ("Must set NotificationReceiver.receive from within " +
                   "an activity");
        }
#end
        mLock.lock();
        if (mSingleReceiver) {
            if (mListenerCount > 0) {
                mListeners = new haxe.ds.ObjectMap<Activity, Void -> Void>();
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
            // a call for each deferred notification
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
            mLock.unlock();
            f();
        }
    }

    private var mSingleReceiver : Bool;
    private var mLock : Mutex;
    private var mNotificationCount : Int;
    private var mListeners : haxe.ds.ObjectMap<Activity, Void -> Void>;
    private var mListenerCount : Int;
    private var mResendClosure : Void -> Void;
    private var mCallbackClosure : Void -> Void;
}
