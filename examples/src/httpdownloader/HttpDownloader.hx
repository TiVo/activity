
/**
 * This is an example for the Activity library
 * 
 * Multiple clients connect to a proxy server sending HTTP GET
 * request on behalf of the clients. The clients store the 
 * HTTP response to disk
 */
import activity.Activity;
import activity.CallMe;
import activity.MessageQueue;
import activity.NotificationQueue;
import activity.Socket;
import activity.Timer;
import sys.io.File;
import haxe.io.Bytes;
import haxe.io.Eof;
import sys.io.FileOutput;

/**
 * Start a proxy server and one client for each host to request
 */
class HttpDownloader
{
    public static function main()
    {
        //the hosts to request are provided by CLI
        //as a space separated list
        //example: tivo.com google.com haxe.org
        var hosts = Sys.args();
        
        Activity.create(function () {
                new ProxyServer(hosts.length);
            });

        for (host in hosts) {
            Activity.create(function () {
                new Client(host);
            });
        }

        Activity.run();
    }
}

/**
 * Used to keep state while retrieving
 * hostname to request from client
 */
typedef ClientData = 
{
    var buffer:Bytes;
    var pos:Int;
}

/**
 * A socket server proxying HTTP request and sending the HTTP
 * response back to the client
 *
 */
class ProxyServer
{
    /**
     * Number of bytes to describe the size of the hostname to request
     */
    public static inline var CONTENT_FIELD_LENGTH:Int = 2;

    /**
     * hostname to listen
     */
    public static inline var SERVER_HOST:String = 'localhost';

    /**
     * port to listen
     */
    public static inline var SERVER_PORT:Int = 5678;

    /**
     * Maximum size of a valid hostname
     */
    public static inline var MAX_HOST_LENGTH = 4 * 1024;

    /**
     * Max simultaneous client connections
     */
    private static inline var MAX_CONNECTIONS:Int = 5;

    /**
     * The listening socket
     */
    private var mSocket:Socket;

    /**
     * A queue used to notifify when an HTTP request is done.
     * Once all requests are done, the server can shutdown
     */
    private var mNotificationQueue:NotificationQueue;

    /**
     * Number of hosts to request before the server can
     * shutdown
     */
    private var mHostsCount:Int;

    public function new(hostsCount:Int)
    {
        mHostsCount = hostsCount;
        mNotificationQueue = new NotificationQueue();
        mNotificationQueue.receiver.receive = this.onRequestComplete;

        mSocket = new Socket();
        mSocket.onReadable = this.onListeningSocketReadable;
        mSocket.listen(SERVER_HOST, SERVER_PORT, MAX_CONNECTIONS);
    }

    /**
     * Accepts client connections once the server is readable
     */
    private function onListeningSocketReadable(socket:Socket)
    {
        var clientSocket = socket.accept();
        if (clientSocket == null) {
            throw 'could not accept client connection';
        }

        //init state to keep track of the client connection
        clientSocket.custom = createClientSocketData();
        clientSocket.onReadable = this.onClientSocketReadable;
    }

    /**
     * Read the hostname to request from the client and send the HTTP request
     */
    private function onClientSocketReadable(socket:Socket)
    {
        var socketData:ClientData = socket.custom;

        //loop until all the data is read from the client which is at most
        //a few Kb
        while(true) {
            try {
                var amt_read = socket.readBytes(socketData.buffer, socketData.pos, socketData.buffer.length - socketData.pos);
                socketData.pos += amt_read;

                //check if the hostname length has been read
                if (socketData.pos >= CONTENT_FIELD_LENGTH) {
                    var contentLength = socketData.buffer.get(0);
                    if (contentLength > MAX_HOST_LENGTH) {
                        throw 'the hostname is too long';
                    }

                    //check if the whole hostname length has been read
                    if (socketData.pos >= contentLength + CONTENT_FIELD_LENGTH) {

                        //when it is, stop reading from the client and start the HTTP request
                        socket.onReadable = null;
                        Activity.create(function () {
                            var hostBytes = socketData.buffer.sub(CONTENT_FIELD_LENGTH, contentLength);
                            new HttpClient(hostBytes.toString(), socket, mNotificationQueue);
                        });

                        //the http request started, we can exit the loop
                        return;
                    }
                }
            }
            catch (e: Eof) {
                throw 'not enough bytes sent by the client';
            }
        }
    }

    /**
     * Create initial data to retrieve client provided hostname
     */
    private function createClientSocketData():ClientData
    {
        return {
            buffer: Bytes.alloc(CONTENT_FIELD_LENGTH + MAX_HOST_LENGTH),
            pos: 0
        }
    }

    /**
     * Called for each completed (success or failure)
     * HTTP request. If all the hosts have been requested,
     * the server can be closed
     */ 
    private function onRequestComplete()
    {
        mHostsCount--;
        if (mHostsCount == 0) {
            trace('DONE !');
            mSocket.close();
        }
    }
}

/**
 * Keep track of bytes state during
 * asynchronous read or write operations
 */ 
typedef BytesState = {
    var pos:Int;
    var length:Int;
}

/**
 * Request a provided host using a simplified GET HTTP call.
 * Write the HTTP response to a provided client socket
 */
class HttpClient
{
    private var mClientSocket:Socket;

    private var mHttpClientSocket:Socket;

    private var mHttpGet:Bytes;

    /**
     * Queue used to notify the proxy server once the HTTP
     * request is complete
     */
    private var mNotificationQueue:NotificationQueue;

    private var mHttpResponse:Bytes;


    public function new(host:String, clientSocket:Socket, notificationQueue:NotificationQueue)
    {
        mClientSocket = clientSocket;
        mNotificationQueue = notificationQueue;

        //the GET request with the provided host
        mHttpGet = Bytes.ofString('GET / HTTP/1.1\r\nHost: $host\r\nConnection: close\r\n\r\n');

        //preallocate bytes for the http response chunks
        mHttpResponse = Bytes.alloc(32 * 1024);

        mHttpClientSocket = new Socket();
        mHttpClientSocket.custom = {pos: 0, length: mHttpGet.length};

        mHttpClientSocket.onWritable = this.onHttpClientSocketWritable;
        mHttpClientSocket.connect(host, 80);
    }

    /**
     * Read the chunks returned by the HTTP request
     */ 
    private function onHttpClientSocketReadable(socket:Socket)
    {
        try {
            var amt_read = socket.readBytes(mHttpResponse, 0, mHttpResponse.length);
            //store the number of bytes which needs to be sent to the client
            socket.custom.amt_read = amt_read;

            //no data to write to the client available now
            if (amt_read == 0) {
                return;
            }
            else {
                //once we get data to write to the client, stop reading
                //until all the data has been written
                socket.onReadable = null;
                socket.custom.pos = 0;
                mClientSocket.onWritable = onClientSocketWritable;
            }
        }
        //an Eof was send, the HTTP response is complete
        catch (e: Eof) {
            //if the http request is complete, close connections
            socket.close();
            mClientSocket.close();
            mNotificationQueue.sender.send();
        }
    }

    /**
     * Write the HTTP response to the client
     */
    private function onClientSocketWritable(socket:Socket)
    {
        try {
            //get the amount of data to write and the current writing position
            var amt_read = mHttpClientSocket.custom.amt_read;
            var pos = mHttpClientSocket.custom.pos;

            //write as much data as possible
            var amt_written = socket.writeBytes(mHttpResponse, pos, amt_read);

            //increment position for next write if not all data are written
            pos += amt_written;
            mHttpClientSocket.custom.pos = pos;

            //if all data have been written, set the HTTP socket to read more data
            if (pos == amt_read) {
                socket.onWritable = null;
                mHttpClientSocket.onReadable = this.onHttpClientSocketReadable;
            }
        }
        catch (e: Eof) {
            throw 'could not write the HTTP response to the client';
        }
    }

    /**
     * Write the HTTP GET request to the server
     */
    private function onHttpClientSocketWritable(socket:Socket)
    {
        var writeState:BytesState = socket.custom;
        try {
            var amt_written = socket.writeBytes(mHttpGet, writeState.pos, writeState.length - writeState.pos);
            writeState.pos += amt_written;

            if (writeState.pos == writeState.length) {
                socket.onWritable = null;

                socket.custom = {pos: 0, length: 0};
                socket.onReadable = this.onHttpClientSocketReadable;
            }
        }
        catch (e: Eof) {
            throw 'could not send HTTP GET request to the server';
        }
    }
}

/**
 * Connects to the proxy server to send a GET HTTP request
 * through it
 */
class Client
{
    private var mHost:String;

    /**
     * The bytes containing the content length and host to request
     */
    private var mRequestBytes:Bytes;

    /**
     * The bytes containing the HTTP response from the proxy server
     */
    private var mResponseBytes:Bytes;
    
    /**
     * A handle to the file where the HTTP response
     * is written
     */
    private var mFile:FileOutput;

    public function new(host:String)
    {
        mHost = host;

        //setup the bytes to send the content length and hostname to the server
        var hostBytes = Bytes.ofString(mHost);

        mRequestBytes = Bytes.alloc(ProxyServer.CONTENT_FIELD_LENGTH + hostBytes.length);

        mResponseBytes = Bytes.alloc(32 * 1024);

        //write the hostname length in the first 2 bytes, then the hostname
        mRequestBytes.set(0, mHost.length);
        mRequestBytes.blit(ProxyServer.CONTENT_FIELD_LENGTH, hostBytes, 0, hostBytes.length);

        var socket = new Socket();
        socket.custom = {pos:0, length:mRequestBytes.length};

        socket.onWritable = this.onClientSocketWritable;
        socket.connect(ProxyServer.SERVER_HOST, ProxyServer.SERVER_PORT);
    }

    /**
     * Send request to server
     */
    private function onClientSocketWritable(socket:Socket)
    {
        var bytesState:BytesState = socket.custom;
        try {
            var amt_written = socket.writeBytes(mRequestBytes, bytesState.pos, mRequestBytes.length - bytesState.pos);
            bytesState.pos += amt_written;

            //check if the complete request has been sent
            if (bytesState.pos == mRequestBytes.length) {

                //once the request has been sent, open the file
                //where the HTTP response will be written
                mFile = File.write(mHost);

                socket.onWritable = null;
                socket.onReadable = this.onClientSocketReadable;
            }
        }
        catch (e: Eof) {
            throw 'could not write to the server';
        }
    }

    /**
     * Read the chunks of the response of the HTTP request
     * and write them to a file
     */
    private function onClientSocketReadable(socket:Socket)
    {
        try {
            var amt_read = socket.readBytes(mResponseBytes, 0, mResponseBytes.length);
            var amt_written = mFile.writeBytes(mResponseBytes, 0, amt_read);
        }
        catch (e: Eof) {
            socket.close();
            mFile.close();
        }
    }
}

