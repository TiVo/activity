/**
 * Copyright 2015 TiVo, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/
package activity;

// No Javascript implementation available
// No Flash version (yet)
#if (!js && !flash)

import activity.impl.Scheduler;


/**
 * Socket implemetation, akin to sys.net.Socket, but integrated into the
 * activity system so that socket events can be delivered via Activity
 * callbacks.
 *
 * Available on all platforms that sys.net.Socket or flash.net.Socket is
 * available on:
 * cpp, cs, java, neko, php, python, flash
 * Not available on platforms that sys.net.Socket and flash.net.Socket is not
 * available on:
 * js
 *
 * The API documentation for this class is basically identical to that of
 * sys.net.Socket, except where comments within the class definition indicate
 * otherwise.
 **/
class Socket
{
    public var custom : Dynamic;
    
    /**
     * Set this to specify the function to call when the Socket becomes
     * readable.  This function is called back in the Activity that sets the
     * readable property.  This function can be set by only one Activity at a
     * time; subsequent changes to this property overwrite any prior value.
     * In other words, Socket supports only a single onReadable callback to be
     * registered at a time.
     **/
    public var onReadable(null, set_onReadable) : Socket -> Void;

    /**
     * Set this to specify the function to call when the Socket becomes
     * writable.  This function is called back in the Activity that sets the
     * readable property.  This function can be set by only one Activity at a
     * time; subsequent changes to this property overwrite any prior value.
     * In other words, Socket supports only a single onReadable callback to be
     * registered at a time.
     **/
    public var onWritable(null, set_onWritable) : Socket -> Void;

    public static function setPollInterval(seconds : Float)
    {
        Scheduler.setSocketPollInterval(seconds);
    }

    public function new()
    {
        mConnectionId = 0;
        mSysNetSocket = this.createSysNetSocket();
        if (mSysNetSocket != null) {
            mWriteArray = [ mSysNetSocket ];
        }
        mInputBytes = haxe.io.Bytes.alloc(16 * 1024);
    }

    public function accept() : Socket
    {
        var socket = mSysNetSocket.accept();
        if (socket == null) {
            return null;
        }
        socket.setBlocking(false);

        return new AcceptedSocket(socket);
    }

    public function close()
    {
        mConnectionId += 1;
        Scheduler.socketReadable(null, mSysNetSocket);
        Scheduler.socketWritable(null, mSysNetSocket);
        mSysNetSocket.close();
    }

    public function connect(host : String, port : Int)
    {
#if flash
#else
        mSysNetSocket.connect(new sys.net.Host(host), port);
#if neko
        // Nonblocking connect is not allowed on neko platform, so only
        // set nonblocking after connect
        mSysNetSocket.setBlocking(false);
#end
#end
    }

    public function host() : { ip : String, port : Int }
    {
        var raw = mSysNetSocket.host();
        return { ip : ipToString(raw.host.ip), port : raw.port };
    }

#if !flash
    /**
     * Sets this Socket up as a listener for new connections from peers.  This
     * call replaces the bind() and listen() functions with a single listen()
     * function.  New clients connections are ready to be accepted when this
     * socket is readable (so setting the onReadable property will cause a
     * callback to be made when new clients can be accepted).
     *
     * @param host is the host to listen as
     * @param port is the port to listen on
     * @param connections is the size of the queue of incoming client
     *        connections to be accepted; this does not limit the number of
     *        clients that can be accepted by this Socket, only the maximum
     *        number that can be queued up waiting for accept() at once.
     **/
    public function listen(host : String, port : Int, connections : Int)
    {
        mSysNetSocket.bind(new sys.net.Host(host), port);
        mSysNetSocket.listen(connections);
    }
#end

    public function peer() : { ip : String, port : Int }
    {
        var raw = mSysNetSocket.peer();
        return { ip : ipToString(raw.host.ip), port : raw.port };
    }

    public function setFastSend(b : Bool)
    {
        mSysNetSocket.setFastSend(b);
    }

    /**
     * Writes bytes to the remote peer.  Throws haxe.io.Eof of the connection
     * is broken, otherwise, returns number of bytes written (which could be 0
     * if none could be written).
     *
     * @param bytes is the bytes to write
     * @param offset is the offset within bytes to start writing from
     * @param length is the number of bytes to write
     * @return the number of bytes written, which may be 0 if network buffers
     *   are full
     **/
    public function writeBytes(bytes : haxe.io.Bytes, offset : Int,
                               length : Int) : Int
    {
        try {
            return mSysNetSocket.output.writeBytes(bytes, offset, length);
        }
        catch (e : haxe.io.Error) {
            switch (e) {
            case Blocked:
                return 0;
            default:
                throw gEof;
            }
        }
        catch (e : Dynamic) {
            throw gEof;
        }
    }

    /**
     * Reads bytes from the remote peer.  Throws haxe.io.Eof of the connection
     * is broken, otherwise, returns number of bytes read (which could be 0 if
     * none were available).
     *
     * @param bytes is the bytes into which to read
     * @param offset is the offset within bytes to start reading into
     * @param length is the number of bytes to read
     * @return the number of bytes read, which may be 0 if there is no
     *   data available
     **/
    public function readBytes(bytes : haxe.io.Bytes, offset : Int,
                              length : Int) : Int
    {
        try {
            return mSysNetSocket.input.readBytes(bytes, offset, length);
        }
        catch (e : haxe.io.Error) {
            switch (e) {
            case Blocked:
                return 0;
            default:
                throw gEof;
            }
        }
        catch (e : Dynamic) {
            throw gEof;
        }
    }

    /**
     * Convenience function that writes a String to the remote peer, blocking
     * until the entire String is written.  NOTE that this is a BLOCKING call,
     * and is not appropriate for anything except quick and dirty testing.
     *
     * Throws haxe.io.Eof on failure to write the entire String.
     **/
    public function writeString(s : String)
    {
        var bytes = haxe.io.Bytes.ofString(s);
        var pos = 0;

        while (pos < bytes.length) {
            var amt_written = this.writeBytes
                (bytes, pos, bytes.length - pos);
            if (amt_written == 0) {
                try {
                    sys.net.Socket.select(null, [ mSysNetSocket ], null);
                }
                catch (e : Dynamic) {
                    throw gEof;
                }
            }
            else {
                pos += amt_written;
            }
        }
    }

    /**
     * Convenience function that reads bytes from the remote peer, blocking
     * until all of the bytes are available.  NOTE that this is a BLOCKING
     * call, and is not appropriate for anything except quick and dirty
     * testing.
     *
     * Throws haxe.io.Eof on failure to read the bytes
     **/
    public function readFully(bytes : haxe.io.Bytes)
    {
        var pos = 0;
        
        while (pos < bytes.length) {
            var amt_read = this.readBytes
                (bytes, pos, bytes.length - pos);
            if (amt_read == 0) {
                try {
                    sys.net.Socket.select([ mSysNetSocket ], null, null);
                }
                catch (e : Dynamic) {
                    throw gEof;
                }
            }
            else {
                pos += amt_read;
            }
        }
    }


    // ------------------------------------------------------------------------
    // Private implementation follows -- please ignore.
    // ------------------------------------------------------------------------

    private function createSysNetSocket() : sys.net.Socket
    {
        var ret = new sys.net.Socket();
#if !neko
        // Nonblocking connect is not allowed on neko platform, so only set
        // nonblocking after connect
        ret.setBlocking(false);
#end
        return ret;
    }

    private function set_onReadable(f : Socket -> Void) : Socket -> Void
    {
        if (f == null) {
            Scheduler.socketReadable(null, mSysNetSocket);
        }
        else {
            var connectionId = mConnectionId;
            Scheduler.socketReadable(function ()
                                     {
                                         if (connectionId == mConnectionId) {
                                             f(this);
                                         }
                                     }, mSysNetSocket);
        }
        return f;
    }

    private function set_onWritable(f : Socket -> Void) : Socket -> Void
    {
        if (f == null) {
            Scheduler.socketWritable(null, mSysNetSocket);
        }
        else {
            var connectionId = mConnectionId;
            Scheduler.socketWritable(function ()
                                     {
                                         if (connectionId == mConnectionId) {
                                             f(this);
                                         }
                                     }, mSysNetSocket);
        }
        return f;
    }

    private static function ipToString(ip : Int) : String
    {
        return (Std.string((ip >> 24) & 0xFF) + "." + 
                Std.string((ip >> 16) & 0xFF) + "." +
                Std.string((ip >>  8) & 0xFF) + "." +
                Std.string(ip & 0xFF));
    }

    private var mConnectionId : Int;
#if flash
    private var mFlashSocket : FlashSocket;
    private var mCustom : Dynamic;
#else
    private var mSysNetSocket : sys.net.Socket;
    private var mWriteArray : Array<sys.net.Socket>;
#end

    // Work around Haxe implementation flaws with minimal churn
    private var mInputBytes : haxe.io.Bytes;
    private static var gEof = new haxe.io.Eof();
}


#if flash
// XXX todo -- for Flash, implement a version of flash.net.Socket that doesn't
// use the normal dispatchEvent mechanism, instead it just schedules activity
// callbacks as necessary.  This will prevent socket events from being flung
// around the display object hierarchy by the event dispatcher.  This is
// accomplished by overriding dispatchEvent to prevent it from actually
// dispatching the event as normal.
private class FlashSocket extends flash.net.Socket
{
    public function new()
    {
        super();
    }

    override public function dispatchEvent(event : flash.events.Event) : Bool
    {
        return true;
    }
}


#else
private class AcceptedSocket extends Socket
{
    public function new(socket : sys.net.Socket)
    {
        super();
        mSysNetSocket = socket;
        mWriteArray = [ mSysNetSocket ];
    }

    private override function createSysNetSocket() : sys.net.Socket
    {
        // Does not create the Socket; the Socket is set after accept
        return null;
    }
}
#end

#end // !js
