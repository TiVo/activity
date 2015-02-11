/** *************************************************************************
 * UdpSocket.hx
 *
 * Copyright 2014 TiVo, Inc.
 ************************************************************************** **/

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
