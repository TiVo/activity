package activity;

import activity.MessageQueue;

/**
 * MessageReceiver is the receiving half of a MessageQueue.  Any Activity may
 * register interest in receiving messages by setting the receive property,
 * which makes the function thus provided a candidate for being called when a
 * message is sent on the corresponding MessageSender.  Note that the activity
 * scheduler internally chooses which Activity receives any given message
 * (attempting to choose the 'least busy' Activity), so for a MessageQueue for
 * which there are multiple receivers, there is no guarantee which receiver
 * will receive which message, and the messages will almost certainly not be
 * divided evenly among the receivers.  The only guarantee is that for every
 * message sent, *some* receiver will receive it.
 **/
@:final
class MessageReceiver<T>
{
    /**
     * Setting this property will cause the Activity which sets it to have
     * notifications called on the function provided.  The function will be
     * called back in the Activity that set the property.  If set to null, no
     * more notifications will be given to the Activity (although they may be
     * given to other Activities independently registered to receive messages).
     **/
    public var receive(null, set_receive) : T -> Void;
    


    // ------------------------------------------------------------------------
    // Private implementation follows -- please ignore.
    // ------------------------------------------------------------------------

    @:allow(activity.MessageQueue)
    private function new(mq : MessageQueue<T>)
    {
        mMq = mq;
    }

    private function set_receive(f : T -> Void) : T -> Void
    {
        mMq.setCurrentActivityReceive(f);
        return f;
    }

    private var mMq : MessageQueue<T>;
}
