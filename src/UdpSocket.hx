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

import activity.Socket;

/**
 * This class is identical to sys.net.UdpSocket, and thus available only on
 * those platforms that support sys.net.UdpSocket, except that it extends from
 * activity.Socket
 **/
class UdpSocket extends Socket
{
    public function new()
    {
        super();
    }

    public function readFrom(buf : Bytes, pos : Int, len : Int,
                             addr : sys.net.Address) : Int
    {
        return mSysNetUdpSocket.readFrom(buf, pos, len, addr);
    }

    public function sendTo(buf : Bytes, pos : Int, len : Int,
                           addr : Address) : Int
    {
        mSysNetUdpSocket.sendTo(buf, pos, len, addr);
    }

    private override function createSysNetSocket() : sys.net.Socket
    {
        return (mSysNetUdpSocket = new sys.net.UdpSocket());
    }

    private var mSysNetUdpSocket : sys.net.UdpSocket;
}
