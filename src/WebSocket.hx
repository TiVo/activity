package activity;

import activity.Activity;

/**
 * Portable WebSocket implementation using Activities.  Only supports client
 * side of WebSocket connections, and only supports the subset of the
 * WebSocket protocol available to Javascript.
 **/
class WebSocket
{
    /**
     * Custom may be set to any value by the user of this WebSocket.  It is a
     * way for the user to associate state with the WebSocket.
     **/
    public var custom(get_custom, set_custom) : Dynamic;
    
    /**
     * Returns the path part of the URL to which this WebSocket is connected
     **/
    public var url_path(default, null) : String;

    /**
     * Returns the subprotocol of this WebSocket, as negotiated by the client
     * and server via handshaking. 
     **/
    public var protocol(default, null) : Null<String>;
    
    /**
     * Set this to specify the funtion to call when a connect() call
     * succeeds.  This is called after the connection completes and the
     * WebSockets handshaking has completed, at which time messages may be
     * sent to the remote peer via send() and will be received by the
     * onMessage callback.  The signature of this function is:
     * 
     * function my_onOpen(webSocket : WebSocket);
     *
     * This callback is made in the Activity that called connect() on the
     * WebSocket.
     **/
    public var onOpen(null, set_onOpen) : WebSocket -> Void;

    /**
     * Set this to specify the function to call on receipt of a new message
     * from the remote peer.  The signature of this function is:
     *
     * function my_onMessage(webSocket : WebSocket, message : Message);
     *
     * Where Message is an enum defined below:
     * Text(string : String)
     * Binary(bytes : haxe.io.Bytes)
     *
     * This callback is made in the Activity that called connect() or accept()
     * on the WebSocket.
     **/
    public var onMessage(null, set_onMessage) : WebSocket -> Message -> Void;

    /**
     * Set this to specify the function to call whenever the WebSocket has
     * been closed by the remote peer.  If a close code and/or reason are
     * available, they are passed in.  This callback is made only if the
     * remote peer initiated a close of a connected WebSocket, or if the
     * underlying network connection failed.  The signature of this function
     * is:
     *
     * function my_onClosedByPeer(webSocket : WebSocket);
     *
     * This callback is made in the Activity that called connect() or accept()
     * on the WebSocket.
     **/
    public var onClosedByPeer(null, set_onClosedByPeer)
        : WebSocket -> Null<Int> -> Null<String> -> Void;

    public function new()
    {
        mState = STATE_CLOSED;
#if js
        mOnOpenNotifier = new activity.NotificationQueue(true);
        mOnMessageQueue = new activity.MessageQueue<Dynamic>(true);
        mOnErrorNotifier = new activity.NotificationQueue(true);
        mOnCloseNotifier = new activity.MessageQueue<Dynamic>(true);
#else
        mOnWritableClosure = this.onWritable;
        mRNG = new RNG();
        mMaskingKeyBytes = [ 0, 0, 0, 0 ];
        mFlushBuffers = new List<FlushBuffer>();
        mInputBuffer = haxe.io.Bytes.alloc(64 * 1024);
        mApplicationData = null;
        mOpcode = 0;
#end
    }

    /**
     * Connect only throws an exception if the WebSocket is already
     * connected.  If the connection failed, it will call back the onClose
     * callback and never call onOpen.
     **/
    public function connect(host : String, port : Int,
                            ?path : String, ?protocols : Array<String>)
    {
        if (mState != STATE_CLOSED) {
            throw "Cannot connect an already connected WebSocket";
        }

        if (path == null) {
            path = "";
        }
        if (protocols == null) {
            protocols = [ ];
        }
        this.url_path = path;

#if js
        // Setting the receivers from within connect is what causes the
        // Activity calling connect() to be the one that the callbacks are
        // made in.
        mOnOpenNotifier.receiver.receive = this.jsOnOpen;
        mOnMessageQueue.receiver.receive = this.jsOnMessage;
        mOnErrorNotifier.receiver.receive = this.jsOnError;
        mOnCloseNotifier.receiver.receive = this.jsOnClose;

        var url = ("ws://" + host + ":" + port +
                   ((path == "") ? "" : ("/" + path)));
        try {
            mJs = untyped __js__("new WebSocket(url, protocols)");
            if (mOnOpen != null) {
                activity.impl.Scheduler.webSocketOnOpen
                    (mJs, mOnOpenNotifier.sender);
            }
            if (mOnMessage != null) {
                activity.impl.Scheduler.webSocketOnMessage
                    (mJs, mOnMessageQueue.sender);
            }
            if (mOnClose != null) {
                activity.impl.Scheduler.webSocketOnError
                    (mJs, mOnErrorNotifier.sender);
                activity.impl.Scheduler.webSocketOnClose
                    (mJs, mOnCloseNotifier.sender);
            }
            mState = STATE_WAITING_FOR_SERVER;
        }
        catch (e : Dynamic) {
            mOnCloseNotifier.sender.send({ code : null, reason : null });
        }
#else
        // Create and connect the activity.Socket
        mActivitySocket = new activity.Socket();
        mActivitySocket.connect(host, port);

        // Generate the key that will be used for this connection
        mKey = this.generateKey();
        
        // Save the protocols so that any response can be checked against them
        mProtocols = protocols;

        // Compute the protocols header
        var protocolsHeader : String;
        if (protocols.length == 0) {
            protocolsHeader = "";
        }
        else {
            protocolsHeader = ("Sec-WebSocket-Protocol: " +
                               protocols.join(", ") + "\r\n");
        }

        // Generate the client handshake and buffer it up, waiting for
        // writable to flush it
        var handshake = haxe.io.Bytes.ofString
            ("GET /" + path + " HTTP/1.1\r\n" +
             "Host: " + host + "\r\n" +
             "Upgrade: websocket\r\n" +
             "Connection: Upgrade\r\n" +
             "Sec-WebSocket-Version: 13\r\n" +
             "Sec-WebSocket-Key: " + mKey + "\r\n" +
             protocolsHeader +
             "\r\n");
        mFlushBuffers.add({ buffer : handshake, offset : 0 });
        mActivitySocket.onWritable = mOnWritableClosure;
        mWatchingWritable = true;
        mOffset = 0;
        mState = STATE_WAITING_FOR_SERVER;
#end
    }

    public function send(message : String)
    {
        if (mState != STATE_OPEN) {
            throw "Cannot call send on WebSocket not in opened state";
        }

        if (!haxe.Utf8.validate(message)) {
            throw "Invalid UTF-8 in outbound WebSocket message";
        }

#if js
        mJs.send(message);
#else
        var bytes = haxe.io.Bytes.ofString(message);

        var msgy = this.createMessage(0x1, bytes);

        mFlushBuffers.add({ buffer : msgy,
                            offset : 0 });

        this.flushBuffers();
#end
    }

    public function close()
    {
        if (mState == STATE_CLOSED) {
            return;
        }
        mState = STATE_CLOSED;
#if js
        activity.impl.Scheduler.webSocketOnOpen(mJs, null);
        activity.impl.Scheduler.webSocketOnMessage(mJs, null);
        activity.impl.Scheduler.webSocketOnError(mJs, null);
        activity.impl.Scheduler.webSocketOnClose(mJs, null);
        mJs.close();
        mJs = null;
        mOnOpenNotifier.sender.clear();
        mOnMessageQueue.sender.clear();
        mOnErrorNotifier.sender.clear();
        mOnCloseNotifier.sender.clear();
        mOnOpenNotifier.receiver.receive = null;
        mOnMessageQueue.receiver.receive = null;
        mOnErrorNotifier.receiver.receive = null;
        mOnCloseNotifier.receiver.receive = null;
#else
        mFlushBuffers.add({ buffer : this.createCloseMessage(1000, null),
                            offset : 0 });
        this.detach();
#end
    }

    private function get_custom() : Dynamic
    {
#if js
        return mCustom;
#else
        return mActivitySocket.custom;
#end
    }

    private function set_custom(custom : Dynamic) : Dynamic
    {
#if js
        mCustom = custom;
#else
        mActivitySocket.custom = custom;
#end
        return custom;
    }

    private function set_onOpen(f : WebSocket -> Void) : WebSocket -> Void
    {
        mOnOpen = f;
#if js
        if (f == null) {
            activity.impl.Scheduler.webSocketOnOpen(mJs, null);
        }
        else if (mState == STATE_WAITING_FOR_SERVER) {
            activity.impl.Scheduler.webSocketOnOpen
                (mJs, mOnOpenNotifier.sender);
        }
#end
        return f;
    }

    private function set_onMessage(f : WebSocket -> Message -> Void)
        : WebSocket -> Message -> Void
    {
        mOnMessage = f;
#if js
        if (f == null) {
            activity.impl.Scheduler.webSocketOnMessage(mJs, null);
        }
        else if (mState != STATE_CLOSED) {
            activity.impl.Scheduler.webSocketOnMessage
                (mJs, mOnMessageQueue.sender);
        }
#end
        return f;
    }

    private function set_onClosedByPeer(f : WebSocket -> Null<Int> -> Null<String> -> Void)
        : WebSocket -> Null<Int> -> Null<String> -> Void
    {
        mOnClose = f;
#if js
        if (f == null) {
            activity.impl.Scheduler.webSocketOnError(mJs, null);
            activity.impl.Scheduler.webSocketOnClose(mJs, null);
        }
        else if (mState != STATE_CLOSED) {
            activity.impl.Scheduler.webSocketOnError
                (mJs, mOnErrorNotifier.sender);
            activity.impl.Scheduler.webSocketOnClose
                (mJs, mOnCloseNotifier.sender);
        }
#end
        return f;
    }

#if js
    private function jsOnOpen()
    {
        mState = STATE_OPEN;
        activity.impl.Scheduler.webSocketOnOpen(mJs, null);
        if (mOnOpen != null) {
            mOnOpen(this);
        }
    }

    private function jsOnMessage(evt : Dynamic)
    {
        if (mState != STATE_OPEN) {
            return;
        }
        if (mOnMessage != null) {
            mOnMessage(this, Text(evt.data));
        }
    }

    private function jsOnError()
    {
        if (mState == STATE_CLOSED) {
            return;
        }
        this.close();
        if (mOnClose != null) {
            mOnClose(this, null, null);
        }
    }

    private function jsOnClose(evt : Dynamic)
    {
        if (mState == STATE_CLOSED) {
            return;
        }
        this.close();
        if (mOnClose != null) {
            mOnClose(this, evt.code, evt.reason);
        }
    }

    private var mCustom : Dynamic;
    private var mJs : js.html.WebSocket;
    private var mOnOpenNotifier : activity.NotificationQueue;
    private var mOnMessageQueue : activity.MessageQueue<Dynamic>;
    private var mOnErrorNotifier : activity.NotificationQueue;
    private var mOnCloseNotifier : activity.MessageQueue<Dynamic>;

#else

    private function onReadable(s : activity.Socket)
    {
        switch (mState) {
        case STATE_CLOSED:
            // Not sure how this can happen?
            // mActivitySocket.onReadable = null;
            
        case STATE_WAITING_FOR_SERVER:
            // Read server handshake
            try {
                var amt_read = mActivitySocket.readBytes
                    (mInputBuffer, mOffset, mInputBuffer.length - mOffset);
                if (amt_read == 0) {
                    return;
                }
                mOffset += amt_read;
            }
            catch (e : Dynamic) {
                this.reset(true);
                if (mOnClose != null) {
                    mOnClose(this, null, null);
                }
                return;
            }
            // Look for CRLFCRLF to end headers
            var i = 0;
            while (i <= (mOffset - 4)) {
                if ((mInputBuffer.get(i + 0) == "\r".code) &&
                    (mInputBuffer.get(i + 1) == "\n".code) &&
                    (mInputBuffer.get(i + 2) == "\r".code) &&
                    (mInputBuffer.get(i + 3) == "\n".code)) {
                    break;
                }
                i += 1;
            }

            if (i > (mOffset - 4)) {
                if (mOffset == mInputBuffer.length) {
                    this.closeWithError("Response headers too long");
                }
                return;
            }

            // Got a complete response
            var headers = mInputBuffer.readString(0, i).split("\r\n");
            if (headers.length == 0) {
                this.reset(true);
                if (mOnClose != null) {
                    mOnClose(this, null, "No status returned");
                }
                return;
            }
            if (!StringTools.startsWith(headers[0], "HTTP/1.1 101 ")) {
                this.reset(true);
                if (mOnClose != null) {
                    mOnClose(this, null, "Bad status: " + headers[0]);
                }
                return;
            }

            // Skip i past CRLFCRLF
            i += 4;

            var headerset = new haxe.ds.StringMap<String>();
            for (j in 1 ... headers.length) {
                var header = headers[j];
                var colon = header.indexOf(":");
                var name : String = "";
                var value : String = "";
                if (colon > 0) {
                    name = StringTools.trim(header.substr(0, colon));
                    value = StringTools.trim(header.substr(colon + 1));
                }
                if ((name.length == 0) || (value.length == 0)) {
                    this.closeWithError("Bad header: " + header);
                    return;
                }
                if (headerset.exists(name)) {
                    headerset.set(name, headerset.get(name) + " " + value);
                }
                else {
                    headerset.set(name, value);
                }
            }
            // Check headers
            if (headerset.exists("Sec-WebSocket-Version") &&
                (headerset.get("Sec-WebSocket-Version") != "13")) {
                this.closeWithError("Expected Sec-WebSocket-Version: 13");
                return;
            }
            if (headerset.get("Upgrade").toLowerCase() != "websocket") {
                this.closeWithError("Expected Upgrade: websocket");
                return;
            }
            if (headerset.get("Connection").toLowerCase() != "upgrade") {
                this.closeWithError("Expected Connection: Upgrade");
                return;
            }
            if (headerset.exists("Sec-WebSockets-Extensions")) {
                var extensions = headerset.get("Sec-WebSockets-Extensions");
                if (extensions.length > 0) {
                    this.closeWithError("Disallowed: " +
                                        "Sec-WebSockets-Extensions");
                    return;
                }
            }
            var expectedKey = generateAccept(mKey);
            var acceptedKey = headerset.get("Sec-WebSocket-Accept");
            if (acceptedKey == null) {
                acceptedKey = "";
            }
            if (acceptedKey != expectedKey) {
                this.closeWithError("Expected Sec-WebSocket-Accept: " +
                                    expectedKey);
                return;
            }
            mState = STATE_OPEN;
            if (mOnOpen != null) {
                mOnOpen(this);
            }
            if (mState == STATE_OPEN) {
                mReadingApplicationData = false;
                mHeaderBytesRequired = 2;
                var remaining = mOffset - i;
                if (remaining > 0) {
                    mInputBuffer.blit(0, mInputBuffer, i, remaining);
                    mOffset = remaining;
                    this.handleHeaderData();
                    this.readData();
                }
                else {
                    mOffset = 0;
                }
            }

        case STATE_OPEN:
            // Read more of next frame
            this.readData();
        }
    }

    private function readData()
    {
        try {
            while (mState != STATE_CLOSED) {
                if (mReadingApplicationData) {
                    var amt_read = mActivitySocket.readBytes
                        (mApplicationData, mOffset,
                         mApplicationDataLength - mOffset);
                    if (amt_read == 0) {
                        break;
                    }
                    mOffset += amt_read;
                    this.handleApplicationData();
                }
                else {
                    var amt_read = mActivitySocket.readBytes
                        (mInputBuffer, mOffset,
                         mInputBuffer.length - mOffset);
                    if (amt_read == 0) {
                        break;
                    }
                    mOffset += amt_read;
                    this.handleHeaderData();
                }
            }
        }
        catch (e : Dynamic) {
            this.reset(true);
            if (mOnClose != null) {
                mOnClose(this, null, null);
            }
            return;
        }
    }

    private function handleHeaderData()
    {
        if (mOffset < mHeaderBytesRequired) {
            return;
        }
        
        switch (mHeaderBytesRequired) {
        case 2:
            var val = mInputBuffer.get(0);
            mFin = ((val & 0x80) != 0);
            var opcode = val & 0x0F;
            switch (opcode) {
            case OPCODE_CONTINUATION:
                if ((mOpcode != OPCODE_TEXT) &&
                    (mOpcode != OPCODE_BINARY)) {
                    this.closeWithError("Cannot continue frame");
                    return;
                }

            case OPCODE_TEXT,
                 OPCODE_BINARY:
                mOpcode = opcode;
                
            case OPCODE_CLOSED,
                 OPCODE_PING,
                 OPCODE_PONG:
                if (!mFin) {
                    this.closeWithError("FIN flag required");
                    return;
                }
                mOpcode = opcode;
                
            default:
                this.closeWithError("Disallowed opcode: 0x" + 
                                    StringTools.hex(mOpcode, 1));
                return;
            }
            val = mInputBuffer.get(1);
            if ((val & 0x80) != 0) {
                this.closeWithError("Server masking disallowed");
                return;
            }
            val &= 0x7F;
            if (val < 126) {
                mApplicationDataLength = val;
            }
            else if (val == 126) {
                mHeaderBytesRequired = 4;
                this.handleHeaderData();
                return;
            }
            else {
                mHeaderBytesRequired = 10;
                this.handleHeaderData();
                return;
            }
            
        case 4:
            mApplicationDataLength = ((mInputBuffer.get(2) << 8) + 
                                      (mInputBuffer.get(3) << 0));
            

        default: // 10
            // Don't handle messages larger than 1 GB.  Haxe max Int is 2 GB,
            // but seriously, what kind of fool tries to send a 1 GB
            // WebSockets message anyway?  The WebSockets protocol is more or
            // less designed to allow WebSocket peers to hose each other in
            // numerous ways, so no attempt is made here to limit the message
            // size to avoid DOS attacks and such.
            if ((mInputBuffer.get(2) != 0) ||
                (mInputBuffer.get(3) != 0) ||
                (mInputBuffer.get(4) != 0) ||
                (mInputBuffer.get(5) != 0) ||
                ((mInputBuffer.get(6) & 0xC0) != 0)) {
                this.closeWithError("Disallowed message from peer larger " +
                                    "than 1 GB");
                return;
            }
            mApplicationDataLength = ((mInputBuffer.get(6) << 24) +
                                      (mInputBuffer.get(7) << 16) +
                                      (mInputBuffer.get(8) <<  8) +
                                      (mInputBuffer.get(9) <<  0));
        }

        // Don't allow more than 8K data in a ping, pong, or close frame
        switch (mOpcode) {
        case OPCODE_PING,
             OPCODE_PONG,
             OPCODE_CLOSED:
            if (mApplicationDataLength > (8 * 1024)) {
                this.closeWithError("Invalid application data length in non " +
                                    "message frame");
                return;
            }
        default:
        }

        if (mApplicationDataLength > mInputBuffer.length) {
            mApplicationData = haxe.io.Bytes.alloc(mApplicationDataLength);
        }
        else {
            mApplicationData = mInputBuffer;
        }

        mOffset -= mHeaderBytesRequired;
        mReadingApplicationData = true;
        if (mOffset > 0) {
            mApplicationData.blit(0, mInputBuffer, mHeaderBytesRequired,
                                  mOffset);
            this.handleApplicationData();
        }
    }

    private function handleApplicationData()
    {
        if (mOffset < mApplicationDataLength) {
            return;
        }

        if (mOpcode == OPCODE_PING) {
            // Probably should try to limit PING/PONGs, but whatever.
            // WebSockets is so brain dead, why bother.
            // Don't bother trying to send the PONG ahead of app data.  If the
            // peer is too dumb to realize that message frames are just as
            // valid an indicator of liveness as PONG frames are, then screw
            // them.
            mFlushBuffers.add({ buffer : this.createMessage(OPCODE_PONG, null),
                                offset : 0 });
        }
        else if (mOpcode == OPCODE_PONG) {
            // Who cares?
        }
        else if (mOpcode == OPCODE_CLOSED) {
            mActivitySocket.onReadable = null;
            if (mOnClose != null) {
                var code : Null<Int> = null;
                var message : Null<String> = null;
                if (mApplicationDataLength > 1) {
                    code = ((mApplicationData.get(0) << 8) +
                            (mApplicationData.get(1) << 0));
                    if (mApplicationDataLength > 2) {
                        message = mApplicationData.readString
                            (2, mApplicationDataLength - 2);
                        if (!haxe.Utf8.validate(message)) {
                            message = null;
                        }
                    }
                }
                mOnClose(this, code, message);
            }
        }
        else {
            var applicationData : String = mApplicationData.readString
                (0, mApplicationDataLength);
            if (mFin) {
                // This is the last segment of the message
                if (mMessageBuf != null) {
                    mMessageBuf.add(applicationData);
                    applicationData = mMessageBuf.toString();
                    mMessageBuf = null;
                }
                var message : Message;
                if (mOpcode == OPCODE_TEXT) {
                    if (!haxe.Utf8.validate(applicationData)) {
                        this.closeWithError("Invalid UTF-8 in inbound " +
                                            "WebSocket message");
                        return;
                    }
                    message = Text(Std.string(applicationData));
                }
                else {
                    message =
                        Binary(haxe.io.Bytes.ofString(applicationData));
                }
                if (mOnMessage != null) {
                    mOnMessage(this, message);
                }
            }
            else {
                if (mMessageBuf == null) {
                    mMessageBuf = new StringBuf();
                }
                mMessageBuf.add(applicationData);
            }
        }

        mReadingApplicationData = false;
        mOffset = 0;
    }

    private function closeWithError(str : String)
    {
        mFlushBuffers.add
            ({ buffer : createCloseMessage(1002, str), offset : 0 });
        this.detach();
        if (mOnClose != null) {
            mOnClose(this, null, str);
        }
    }

    private function onWritable(s : activity.Socket)
    {
        this.flushBuffers();

        if ((mState == STATE_WAITING_FOR_SERVER) && mFlushBuffers.isEmpty()) {
            mActivitySocket.onReadable = this.onReadable;
        }
    }

    private function generateKey() : String
    {
        // Generate a random 16 byte value
        var bytes = haxe.io.Bytes.alloc(16);
        var idx = 0;
        for (i in 0 ... 4) {
            var v = mRNG.next();
            bytes.set(idx++, (v >> 24) & 0xFF);
            bytes.set(idx++, (v >> 16) & 0xFF);
            bytes.set(idx++, (v >>  8) & 0xFF);
            bytes.set(idx++, (v >>  0) & 0xFF);
        }
        return haxe.crypto.Base64.encode(bytes);
    }

    private static function generateAccept(key : String) : String
    {
        return (haxe.crypto.Base64.encode
                (haxe.crypto.Sha1.make
                 (haxe.io.Bytes.ofString
                  (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))));
    }

    private function createCloseMessage(?status : Int, ?reason : String)
        : haxe.io.Bytes
    {
        if (status == null) {
            return createMessage(0x8, null);
        }

        if ((status < 0) || (status > 0xFFFF)) {
            throw "Invalid status for WebSocket close";
        }

        if (reason == null) {
            var bytes = haxe.io.Bytes.alloc(2);
            bytes.set(0, (status >> 8) & 0xFF);
            bytes.set(1, (status >> 0) & 0xFF);
            return createMessage(0x8, bytes);
        }

        var bytes = haxe.io.Bytes.alloc(2 + reason.length);
        bytes.set(0, (status >> 8) & 0xFF);
        bytes.set(1, (status >> 0) & 0xFF);
        bytes.blit(2, haxe.io.Bytes.ofString(reason), 0, reason.length);
        return createMessage(0x8, bytes);
    }

    private function createMessage(opcode : Int, bytes : haxe.io.Bytes)
        : haxe.io.Bytes
    {
        var payload_length = (bytes == null) ? 0 : bytes.length;

        var payload_length_length =
            (payload_length < 126) ? 1 :
            (payload_length <= 0xFFFF) ? 3 : 9;

        mMaskingKey = mRNG.next();
        mMaskingKeyBytes[0] = (mMaskingKey >> 24) & 0xFF;
        mMaskingKeyBytes[1] = (mMaskingKey >> 16) & 0xFF;
        mMaskingKeyBytes[2] = (mMaskingKey >>  8) & 0xFF;
        mMaskingKeyBytes[3] = (mMaskingKey >>  0) & 0xFF;

        var ret = haxe.io.Bytes.alloc(1 + payload_length_length + 4 +
                                      payload_length);

        ret.set(0, 0x80 | opcode);

        if (payload_length < 126) {
            ret.set(1, 0x80 | payload_length);
            ret.set(2, (mMaskingKey >> 24) & 0xFF);
            ret.set(3, (mMaskingKey >> 16) & 0xFF);
            ret.set(4, (mMaskingKey >>  8) & 0xFF);
            ret.set(5, (mMaskingKey >>  0) & 0xFF);
            if (bytes != null) {
                var masked = createMasked(bytes);
                ret.blit(6, masked, 0, masked.length);
            }
        }
        else if (payload_length <= 0xFFFF) {
            ret.set(1, 0x80 | 126);
            ret.set(2, (payload_length >> 8) & 0xFF);
            ret.set(3, (payload_length >> 0) & 0xFF);
            ret.set(4, (mMaskingKey >> 24) & 0xFF);
            ret.set(5, (mMaskingKey >> 16) & 0xFF);
            ret.set(6, (mMaskingKey >>  8) & 0xFF);
            ret.set(7, (mMaskingKey >>  0) & 0xFF);
            var masked = createMasked(bytes);
            ret.blit(8, masked, 0, masked.length);
        }
        else {
            ret.set(1, 0x80 | 127);
            ret.set(2, 0);
            ret.set(3, 0);
            ret.set(4, 0);
            ret.set(5, 0);
            ret.set(6, (payload_length >> 24) & 0xFF);
            ret.set(7, (payload_length >> 16) & 0xFF);
            ret.set(8, (payload_length >>  8) & 0xFF);
            ret.set(9, (payload_length >>  0) & 0xFF);
            ret.set(10, (mMaskingKey >> 24) & 0xFF);
            ret.set(11, (mMaskingKey >> 16) & 0xFF);
            ret.set(12, (mMaskingKey >>  8) & 0xFF);
            ret.set(13, (mMaskingKey >>  0) & 0xFF);
            var masked = createMasked(bytes);
            ret.blit(14, masked, 0, masked.length);
        }

        return ret;
    }

    private function reset(close : Bool)
    {
        mWatchingWritable = false;
        if (mActivitySocket != null) {
            if (close) {
                mActivitySocket.close();
            }
            mActivitySocket = null;
        }
        mKey = null;
        mProtocols = null;
        mFlushBuffers = new List<FlushBuffer>();
        mApplicationData = null;
        mMessageBuf = null;
        mOffset = 0;
        mOpcode = 0;
        mState = STATE_CLOSED;
    }

    private function detach()
    {
        // Latch the flush queue
        var closingQueue = mFlushBuffers;
        // Latch the socket
        var closingSocket = mActivitySocket;

        // Re-set internal state to closed
        this.reset(false);

        // Now set up "stealth" management of the closing down of this
        // WebSocket in this Activity
        
        // On writable, flush
        closingSocket.onReadable = null;
        closingSocket.onWritable = function (s : activity.Socket)
        {
            try {
                flush(closingSocket, closingQueue);
                if (closingQueue.isEmpty()) {
                    closingSocket.onWritable = null;
                    // Start a timer to close the socket after 10 seconds,
                    // to try to give the close message and any other
                    // buffered messages time to propogate to the peer,
                    // rather than relying on the underlying socket
                    // implementation having SO_LINGER, which it may or
                    // may not
                    Timer.once(function (f : Float)
                               {
                                   try {
                                       closingSocket.close();
                                   }
                                   catch (e : Dynamic) {
                                   }
                               }, 10, false);
                }
            }
            catch (e : Dynamic) {
                closingSocket.onWritable = null;
                try {
                    closingSocket.close();
                }
                catch (e : Dynamic) {
                }
            }
        };
    }

    private function createMasked(bytes : haxe.io.Bytes) : haxe.io.Bytes
    {
        var ret = haxe.io.Bytes.alloc(bytes.length);
        var i : Int = 0;
        while (i < ret.length) {
            ret.set(i, bytes.get(i) ^ mMaskingKeyBytes[i % 4]);
            i += 1;
        }
        return ret;
    }

    private function flushBuffers()
    {
        try {
            flush(mActivitySocket, mFlushBuffers);
            if (mFlushBuffers.length == 0) {
                mActivitySocket.onWritable = null;
                mWatchingWritable = false;
            }
            else if (!mWatchingWritable) {
                mActivitySocket.onWritable = mOnWritableClosure;
                mWatchingWritable = true;
            }
        }
        catch (e : Dynamic) {
            this.reset(true);
            if (mOnClose != null) {
                mOnClose(this, null, null);
            }
        }
    }

    private static function flush(socket : activity.Socket,
                                  buffers : List<FlushBuffer>)
    {
        while (!buffers.isEmpty()) {
            var buffer = buffers.first();
            if (buffer.buffer.length > 0) {
                buffer.offset += socket.writeBytes
                    (buffer.buffer, buffer.offset,
                     buffer.buffer.length - buffer.offset);
            }
            if (buffer.offset < buffer.buffer.length) {
                break;
            }
            buffers.pop();
        }
    }

    private var mOnWritableClosure : activity.Socket -> Void;
    private var mWatchingWritable : Bool;
    private var mActivitySocket : activity.Socket;
    private var mRNG : RNG;
    private var mKey : String;
    private var mProtocols : Array<String>;
    private var mMaskingKey : Int;
    private var mMaskingKeyBytes : Array<Int>;
    private var mFlushBuffers : List<FlushBuffer>;
    private var mInputBuffer : haxe.io.Bytes;
    private var mHeaderBytesRequired : Int;
    private var mApplicationData : haxe.io.Bytes;
    private var mApplicationDataLength : Int;
    private var mReadingApplicationData : Bool;
    private var mFin : Bool;
    private var mOpcode : Int;
    private var mOffset : Int;
    private var mMessageBuf : StringBuf;

    private static inline var OPCODE_CONTINUATION = 0x0;
    private static inline var OPCODE_TEXT = 0x1;
    private static inline var OPCODE_BINARY = 0x2;
    private static inline var OPCODE_CLOSED = 0x8;
    private static inline var OPCODE_PING = 0x9;
    private static inline var OPCODE_PONG = 0xA;

#end

    private var mState : Int;
    private var mOnOpen : WebSocket -> Void;
    private var mOnMessage : WebSocket -> Message -> Void;
    private var mOnClose : WebSocket -> Null<Int> -> Null<String> -> Void;
    private static inline var STATE_CLOSED = 1;
    private static inline var STATE_WAITING_FOR_SERVER = 2;
    private static inline var STATE_OPEN = 3;
}


enum Message
{
    Text(string : String);
    Binary(bytes : haxe.io.Bytes);
}


#if !js

private typedef FlushBuffer = { buffer : haxe.io.Bytes, offset : Int };

// Simple xorshift random number generator, that mixes in the current time
// occasionally, in an attempt to reduce its predictability.  This was tested
// with the "small crush" suite of TestU01 and was found to fail the same
// tests that a Marsenne Twister implementation failed.
class RNG
{
    public function new()
    {
        mX = 0;
        mY = 0;
        mZ = 0;
        mW = 0;
        this.reseed();
    };

    public function next() : Int
    {
        // Every 100 numbers, mix in the current time
        if (++mSeedCount == 100) {
            this.reseed();
        }

        var t = mX ^ (mX << 11);
        mX = mY;
        mY = mZ;
        mZ = mW;
        mW = mW ^ (mW >> 19) ^ t ^ (t >> 8);

        return mW;
    }

    private function reseed()
    {
        var f = Date.now().getTime();
        if (f > 0xFFFFF) {
            f /= 0xFFFFF;
        }
        mX ^= Std.int(f);
        mY ^= Std.int(f * 10);
        mZ ^= Std.int(f * 1000);
        mW ^= Std.int(f * 100000);
        mSeedCount = 0;
    }

    private var mX : Int;
    private var mY : Int;
    private var mZ : Int;
    private var mW : Int;
    private var mSeedCount : Int;
}

#end
