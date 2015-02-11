package activity;

import activity.NotificationQueue;

/**
 * NotificationSender is the sending half of a NotificationQueue.  It may be
 * used to send notifications to the set of receivers registered to receive
 * notifications via the NotificationReceiver end of the NotificationQueue.
 * For any notification sent, one Activity will be chosen from the set of
 * registered receivers to receive the notification, although it is
 * indeterminite which Activity will be chosen.
 **/
@:final
class NotificationSender
{
    /**
     * Sends a notification to one of the listener Activities registered via
     * the received property.
     **/
    public function send()
    {
        mMq.send();
    }

    /**
     * Clears any notifications that have not yet been received, cancelling
     * them all.
     **/
    public function clear()
    {
        mMq.clear();
    }


    // ------------------------------------------------------------------------
    // Private implementation follows -- please ignore.
    // ------------------------------------------------------------------------

    @:allow(activity.NotificationQueue)
    private function new(mq : NotificationQueue)
    {
        mMq = mq;
    }

    private var mMq : NotificationQueue;
}
