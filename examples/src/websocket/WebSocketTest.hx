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

import activity.Activity;
import activity.WebSocket;

class WebSocketTest
{
    public static function main()
    {
        Activity.create(function ()
                        {
                            new WebSocketTest();
                        },
                        function (e : Dynamic)
                        {
                            trace("UNCAUGHT: " + e);
                            trace("at");
                            trace(haxe.CallStack.exceptionStack().toString());
                            trace(haxe.CallStack.callStack().toString());
                        },
                        "WebSocket");

        Activity.run(function ()
                     {
                         trace("onCompletion");
                     });
    }

    public function new()
    {
        mMessageNumber = 0;
        mWebSocket = new WebSocket();
        mWebSocket.onOpen = function (webSocket : WebSocket)
        {
            trace("Connected");
            for (i in 0 ... 10) {
                this.next();
            }
        };
        mWebSocket.onMessage = function (webSocket : WebSocket,
                                         message : Message)
        {
            switch (message) {
            case Text(string):
                trace("Received text [" + string + "]");
            case Binary(bytes):
                trace("Received binary [" + Std.string(bytes) + "]");
            }            
            this.next();
        };
        mWebSocket.onClosedByPeer = function (webSocket : WebSocket,
                                              code : Null<Int>,
                                              reason : Null<String>)
        {
            trace("Closed by peer: " + code + " -- " + reason);
        };
        mWebSocket.connect("echo.websocket.org", 80);
    }

    private function next()
    {
        if (mMessageNumber == 40) {
            trace("Closing");
            mWebSocket.close();
        }
        else {
            var msg = "Message #" + ++mMessageNumber;
            trace("Sending [" + msg + "]");
            mWebSocket.send(msg);
        }
    }

    private var mMessageNumber : Int;
    private var mWebSocket : WebSocket;
}
