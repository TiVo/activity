
/**
 * ActivityTest implements a class that can perform testing of the Activity
 * API.  This is not a unit test, it is a full test of the Activity API with
 * no mocking.
 *
 * This test can be configured via command line arguments to run a variety
 * of interleaved activities and scheduled calls:
 *
 * act foo initial -- create an activity named foo running the sequence of
 *                    of actions defined by 'initial'
 * fun initial act in2 -- in function initial create an activity named
 *                        running an initial function 'in2'
 * fun initial busy 0.4 -- busy wait 0.4 seconds in the function initial
 * fun initial soon soon1 -- in function initial schedule a soon callback to
 *                           function soon1 (similarly for immediately, later)
 * fun initial timer 0.5 timer1 -- in function initial schedule a timer of
 *                                 0.5 seconds which will run actions listed
 *                                 for timer1
 * fun initial listen 3456 listen1 -- in function initial create a listen
 *                                    socket named listen1 listening on 3456
 * fun initial readable listen1 readable1 -- in function initial, set readable
 *                                           callback for socket 'listen1' to
 *                                           be function 'readable1'
 * fun initial writable listen1 writable1 -- in function initial, set writable
 *                                           callback for socket 'listen1' to
 *                                           be function 'writable1'
 * fun readable1 accept listen1 server1 -- in function readable1, accept
 *                                         on socket listen1, producing a
 *                                         socket named server1
 * fun readable1 sendping server1 -- in function readable1, send a ping on
 *                                   socket server1
 * fun readable1 recvping server1 -- in function readable1, receive a ping on
 *                                   socket server1
 * fun initial queue myqueue -- in function initial create a MessageQueue
 * fun initial receiver myqueue my_receiver -- add my_receiver in the current
 *                                             activity to myqueue's receiver
 * fun initial send myqueue hello -- send "hello" on myqueue
 * fun my_receiver printmsg -- print whatever message was received on queue
 * fun initial connect 3456 client1 -- in function initial, create a socket
 *                                     connected to port 3456 named client1
 * fun initial cancel readable1 -- in function initial, cancel function
 *                                 readable1
 * fun initial shutdown -- in function initial, shutdown current activity
 **/

import activity.Activity;
import activity.CallMe;
import activity.MessageQueue;
import activity.Socket;
import activity.Timer;

class ActivityTest
{
    public static function main()
    {
#if js
        var onFile = function (value : String)
        {
            runTest(new haxe.io.StringInput(value));
        };
        untyped __js__('setOnFile(onFile);');
#elseif flash
#else
        runTest(Sys.stdin());
#end
    }

    private static function runTest(input : haxe.io.Input)
    {
        // Read instructions from stdin
        try {
            while (true) {
                process(input.readLine());
            }
        }
        catch (e : haxe.io.Eof) {
        }

        for (root in gRootActivitiesOrdered) {
            handleAction(NewActivity(root, gRootActivities.get(root)));
        }

        atrace("Running activities begin");

        Activity.run(onComplete);

        atrace("Running activities end");
    }

    private static function onComplete()
    {
        atrace("onComplete");
    }

    private static function process(line : String)
    {
        if ((line.length == 0) || StringTools.startsWith(line, "#")) {
            return;
        }
        var words = line.split(" ");
        if (words[0] == "act") {
            gRootActivitiesOrdered.push(words[1]);
            gRootActivities.set(words[1], words[2]);
        }
        else if (words[0] == "fun") {
            var actions : Array<Action>;
            if (gActions.exists(words[1])) {
                actions = gActions.get(words[1]);
            }
            else {
                actions = [ ];
                gActions.set(words[1], actions);
            }
            if (words[2] == "act") {
                actions.push(NewActivity(words[3], words[4]));
            }
            else if (words[2] == "immediately") {
                actions.push(Immediately(words[3]));
            }
            else if (words[2] == "soon") {
                actions.push(Soon(words[3]));
            }
            else if (words[2] == "later") {
                actions.push(Later(words[3]));
            }
            else if (words[2] == "timer") {
                actions.push(Timeout(Std.parseFloat(words[3]), words[4]));
            }
            else if (words[2] == "busy") {
                actions.push(Busy(Std.parseFloat(words[3])));
            }
            else if (words[2] == "listen") {
                actions.push(Listen(Std.parseInt(words[3]), words[4]));
            }
            else if (words[2] == "connect") {
                actions.push(Connect(Std.parseInt(words[3]), words[4]));
            }
            else if (words[2] == "accept") {
                actions.push(Accept(words[3], words[4]));
            }
            else if (words[2] == "readable") {
                actions.push(Readable(words[3], words[4]));
            }
            else if (words[2] == "writable") {
                actions.push(Writable(words[3], words[4]));
            }
            else if (words[2] == "sendping") {
                actions.push(SendPing(words[3]));
            }
            else if (words[2] == "sendpong") {
                actions.push(SendPong(words[3]));
            }
            else if (words[2] == "recvping") {
                actions.push(ReceivePing(words[3]));
            }
            else if (words[2] == "recvpong") {
                actions.push(ReceivePong(words[3]));
            }
            else if (words[2] == "queue") {
                actions.push(Queue(words[3]));
            }
            else if (words[2] == "receiver") {
                actions.push(Receiver(words[3], words[4]));
            }
            else if (words[2] == "send") {
                actions.push(Send(words[3], words[4]));
            }
            else if (words[2] == "printmsg") {
                actions.push(PrintMsg);
            }
            else if (words[2] == "cancelcallme") {
                actions.push(CancelCallMe(words[3]));
            }
            else if (words[2] == "canceltimer") {
                actions.push(CancelTimer(words[3]));
            }
            else if (words[2] == "shutdown") {
                actions.push(Shutdown);
            }
            else {
                throw "Unknown action on line: " + line;
            }
        }
        else {
            throw "Unknown action on line: " + line;
        }
    }

    private static function handleAction(action : Action)
    {
        switch (action) {
        case NewActivity(name, initial):
            atrace("Create activity: " + name + " begin");
            Activity.create(function ()
                            {
                                atrace("Initializer begin");
                                var actions = gActions.get(initial);
                                for (action in actions) {
                                    handleAction(action);
                                }
                                atrace("Initializer end");
                            },
                            onUncaught,
                            name);
            atrace("Create activity: " + name + " end");

        case Immediately(name):
            var cancelId = 
                CallMe.immediately(function ()
                                   {
                                       atrace("Immediately begin " + name);
                                       var actions = gActions.get(name);
                                       if (actions != null) {
                                           for (action in actions) {
                                               handleAction(action);
                                           }
                                       }
                                       atrace("Immediately end " + name);
                                   },
                                   true);
            gCancels.set(name, cancelId);

        case Soon(name):
            var cancelId = 
                CallMe.soon(function ()
                            {
                                atrace("Soon begin " + name);
                                var actions = gActions.get(name);
                                if (actions != null) {
                                    for (action in actions) {
                                        handleAction(action);
                                    }
                                }
                                atrace("Soon end " + name);
                            },
                            true);
            gCancels.set(name, cancelId);

        case Later(name):
            var cancelId = 
                CallMe.later(function ()
                             {
                                 atrace("Later begin " + name);
                                 var actions = gActions.get(name);
                                 if (actions != null) {
                                     for (action in actions) {
                                         handleAction(action);
                                     }
                                 }
                                 atrace("Later end " + name);
                             },
                             true);
            gCancels.set(name, cancelId);
            
        case Timeout(seconds, name):
            var cancelId = 
                Timer.once(function (latency : Float)
                           {
                               atrace("Timer begin " + name +
                                      " [" + round_10000(latency) + "]");
                               var actions = gActions.get(name);
                               if (actions != null) {
                                   for (action in actions) {
                                       handleAction(action);
                                   }
                               }
                               atrace("Timer end " + name +
                                      " [" + round_10000(latency) + "]");
                           },
                           seconds,
                           true);
            gCancels.set(name, cancelId);
            
        case Busy(seconds):
            atrace("Busy " + seconds + " begin");
            var now = haxe.Timer.stamp();
            var when = now + seconds;
            var last_message = now;
            var next_message = now + 0.1;
            while (true) {
                now = haxe.Timer.stamp();
                if (now >= when) {
                    break;
                }
                if (now >= next_message) {
                    atrace("Busy " + (now - last_message));
                    last_message = next_message;
                    next_message = now + 0.1;
                }
            }
            atrace("Busy " + seconds + " end");

        case Listen(port, name):
#if (js || flash)
            throw "Not supported for this target";
#else
            atrace("Creating server " + name + " on port " + port + " begin");
            var socket = new Socket();
            socket.listen("127.0.0.1", port, 10);
            gSockets.set(name, socket);
            atrace("Creating server " + name + " on port " + port + " end");
#end

        case Connect(port, name):
#if (js || flash)
            throw "Not supported for this target";
#else
            atrace("Creating client " + name + " on port " + port + " begin");
            var socket = new Socket();
            socket.connect("127.0.0.1", port);
            gSockets.set(name, socket);
            atrace("Creating client " + name + " on port " + port + " end");
#end // js || flash

        case Accept(socket_name, name):
#if (js || flash)
            throw "Not supported for this target";
#else
            atrace("Accept " + socket_name + " begin");
            var socket = gSockets.get(socket_name).accept();
            gSockets.set(name, socket);
            atrace("Accept " + socket_name + " end");
#end // js || flash

        case Readable(socket_name, name):
#if (js || flash)
            throw "Not supported for this target";
#else
            if (name == "null") {
                gSockets.get(socket_name).onReadable = null;
            }
            else {
                gSockets.get(socket_name).onReadable =
                function (s : Socket)
                {
                    atrace("Readable " + socket_name + " begin");
                    var actions = gActions.get(name);
                    if (actions != null) {
                        for (action in actions) {
                            handleAction(action);
                        }
                    }
                    atrace("Readable " + socket_name + " end");
                };
            }
#end // js || flash
            
        case Writable(socket_name, name):
#if (js || flash)
            throw "Not supported for this target";
#else
            if (name == "null") {
                gSockets.get(socket_name).onWritable = null;
            }
            else {
                gSockets.get(socket_name).onWritable =
                function (s : Socket)
                {
                    atrace("Writable " + socket_name + " begin");
                    var actions = gActions.get(name);
                    if (actions != null) {
                        for (action in actions) {
                            handleAction(action);
                        }
                    }
                    atrace("Writable " + socket_name + " end");
                };
            }
#end // js || flash

        case SendPing(socket_name):
#if (js || flash)
            throw "Not supported for this target";
#else
            atrace("Send ping " + socket_name + " begin");
            gSockets.get(socket_name).writeString("PING");
            atrace("Send ping " + socket_name + " end");
#end // js || flash
            
        case SendPong(socket_name):
#if (js || flash)
            throw "Not supported for this target";
#else
            atrace("Send pong " + socket_name + " begin");
            gSockets.get(socket_name).writeString("PONG");
            atrace("Send pong " + socket_name + " end");
#end // js || flash

        case ReceivePing(socket_name):
#if (js || flash)
            throw "Not supported for this target";
#else
            atrace("Receive ping " + socket_name + " begin");
            var bytes = haxe.io.Bytes.alloc(4);
            gSockets.get(socket_name).readFully(bytes);
            if (Std.string(bytes) != "PING") {
                throw "Expected PING";
            }
            atrace("Receive ping " + socket_name + " end");
#end // js || flash

        case ReceivePong(socket_name):
#if (js || flash)
            throw "Not supported for this target";
#else
            atrace("Receive pong " + socket_name + " begin");
            var bytes = haxe.io.Bytes.alloc(4);
            gSockets.get(socket_name).readFully(bytes);
            if (Std.string(bytes) != "PONG") {
                throw "Expected PONG";
            }
            atrace("Receive pong " + socket_name + " end");
#end // js || flash

        case Queue(queue_name):
            atrace("Create queue " + queue_name + " begin");
            gQueues.set(queue_name, new MessageQueue<String>());
            atrace("Create queue " + queue_name + " end");

        case Receiver(queue_name, name):
            if (name == "null") {
                gQueues.get(queue_name).receiver.receive = null;
            }
            else {
                gQueues.get(queue_name).receiver.receive =
                function (msg : String)
                {
                    atrace("Receive " + queue_name + " begin");
                    var actions = gActions.get(name);
                    if (actions != null) {
                        for (action in actions) {
                            switch (action) {
                            case PrintMsg:
                                atrace("Received from " + queue_name + ": " +
                                       msg);
                            default:
                                handleAction(action);
                            }
                        }
                    }
                    atrace("Receive " + queue_name + " end");
                };
            }

        case Send(queue_name, text):
            atrace("Send queue " + queue_name + " [" + text + "] begin");
            gQueues.get(queue_name).sender.send(text);
            atrace("Send queue " + queue_name + " [" + text + "] end");

        case PrintMsg:
            throw ("Error - printmsg can only be done within a message queue " +
                   "receiver");

        case CancelCallMe(name):
            atrace("Cancel call me " + name + " begin");
            var toCancel = gCancels.get(name);
            if (toCancel != null) {
                gCancels.remove(name);
                CallMe.cancel(toCancel);
            }
            atrace("Cancel call me " + name + " end");

        case CancelTimer(name):
            atrace("Cancel timer" + name + " begin");
            var toCancel = gCancels.get(name);
            if (toCancel != null) {
                gCancels.remove(name);
                Timer.cancel(toCancel);
            }
            atrace("Cancel timer" + name + " end");

        case Shutdown:
            atrace("Shutdown begin");
            Activity.shutdown();
            atrace("Shutdown end");
        }
    }

    private static function round_10000(f : Float) : Float
    {
        var q = Std.int(f * 10000);
        return (q < 1) ? 0 : (q / 10000);
    }

    private static function onUncaught(e : Dynamic)
    {
        atrace("Caught: " + e);
        if (Std.string(e) == "FATAL ERROR") {
            throw e;
        }
    }

    private static function atrace(msg : String)
    {
        var id = Activity.thisID;
        if (id == null) {
            trace("[]: "+ msg);
        }
        else {
            trace("[" + Activity.thisName + ":" + id + "]: " + msg);
        }
    }

    // Order in which to create root Activities
    private static var gRootActivitiesOrdered : Array<String> = [ ];
    // Names the root Activities
    private static var gRootActivities : ActivityMap = new ActivityMap();
    // Map from Activity/callback name to actions
    private static var gActions : ActionMap = new ActionMap();
    // Most recent cancel id for the given callback
    private static var gCancels : CancelMap = new CancelMap();
#if (!js && !flash)
    // Sockets associated with a given name
    private static var gSockets : SocketMap = new SocketMap();
#end
    // MessageQueues associated with a given name
    private static var gQueues : QueueMap = new QueueMap();
}


private typedef ActivityMap = haxe.ds.StringMap<String>;
private typedef ActionMap = haxe.ds.StringMap<Array<Action>>;
private typedef CancelMap = haxe.ds.StringMap<CancelId>;
#if (!js && !flash)
private typedef SocketMap = haxe.ds.StringMap<Socket>;
#end
private typedef QueueMap = haxe.ds.StringMap<MessageQueue<String>>;


private enum Action
{
    // Create an Activity with the given name, in the given context
    // (null for top level), initially running the given function
    NewActivity(name : String, initial : String);
    // Schedule an immediate callback of the given name, from the given name
    Immediately(name : String);
    // Schedule an immediate callback of the given name, from the given name
    Soon(name : String);
    // Schedule an immediate callback of the given name, from the given name
    Later(name : String);
    // Schedule an immediate callback of the given name, from the given name
    Timeout(seconds : Float, name : String);
    // Busy work a given amount in a callback
    Busy(seconds : Float);
    // Create a server listening on the given port with the given name
    Listen(port : Int, socket_name : String);
    // Create a client connecting to the given port with the given name
    Connect(port : Int, socket_name : String);
    // Accept a new socket on the given socket, giving it the given name.
    // Each new accepted socket will have the same name, although each will
    // independently follow the same sequence of actions
    Accept(socket_name : String, name : String);
    // Create a readable callback on the given socket with the given name
    Readable(socket_name : String, name : String);
    // Create a writable callback on the given socket with the given name
    Writable(socket_name : String, name : String);
    // Write a ping
    SendPing(socket_name : String);
    // Write a pong
    SendPong(socket_name : String);
    // Receive a ping
    ReceivePing(socket_name : String);
    // Receive a pong
    ReceivePong(socket_name : String);
    // Create a MessageQueue<String>
    Queue(queue_name : String);
    // Set receiver for queue
    Receiver(queue_name : String, name : String);
    // Send message on queue
    Send(queue_name : String, text : String);
    // Print message received from queue.  Only valid in queue receiver
    // callback.
    PrintMsg;
    // Cancel scheduled work or stop listening for readable/writable
    CancelCallMe(name : String);
    CancelTimer(name : String);
    // Shutdown current activity
    Shutdown;
}
