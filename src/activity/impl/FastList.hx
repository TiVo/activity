/** *************************************************************************
 * FastList.hx
 *
 * Copyright 2014 TiVo, Inc.
 ************************************************************************** **/

package activity.impl;


class FastList<T : { next : T, prev : T }>
{
    public var head : Null<T>;
    public var length(default, null) : Int;

    public function new()
    {
        this.length = 0;
    }

    public function pushBeforeHead(e : T)
    {
        pushAfterTail(e);
        this.head = e;
    }

    public function pushAfterTail(e : T)
    {
        if (this.head == null) {
            e.prev = e;
            e.next = e;
            this.head = e;
            length += 1;
        }
        else {
            insertBefore(this.head, e);
        }
    }

    public function insertBefore(before : T, toInsert : T)
    {
        toInsert.next = before;
        toInsert.prev = before.prev;
        before.prev.next = toInsert;
        before.prev = toInsert;
        if (before == this.head) {
            this.head = toInsert;
        }
        length += 1;
    }

    public function popHead() : T
    {
        if (this.head == null) {
            return null;
        }
        var ret = this.head;
        if (ret.next == ret) {
            this.head = null;
        }
        else {
            this.head = ret.next;
            ret.prev.next = ret.next;
            ret.next.prev = ret.prev;
        }
        ret.prev = null;
        ret.next = null;
        length -= 1;
        return ret;
    }

    public function findAndRemove(test : T -> Bool) : Null<T>
    {
        if (this.head == null) {
            return null;
        }

        var current = this.head;
        do {
            if (test(current)) {
                if (current == this.head) {
                    if (current.next == current) {
                        this.head = null;
                        current.prev = null;
                        current.next = null;
                        return current;
                    }
                    else {
                        this.head = current.next;
                    }
                }
                current.prev.next = current.next;
                current.next.prev = current.prev;
                current.prev = null;
                current.next = null;
                length -= 1;
                return current;
            }
            current = current.next;
        } while (current != this.head);

        return null;
    }

    public function removeMatches(test : T -> Bool, onRemove : T -> Void)
    {
        if (this.head == null) {
            return;
        }

        // Look at the entire list except for the head
        var current = this.head.next;
        while (current != this.head) {
            var next = current.next;
            if (test(current)) {
                onRemove(current);
                current.prev.next = current.next;
                current.next.prev = current.prev;
                current.prev = null;
                current.next = null;
                length -= 1;
            }
            current = next;
        }

        // Now look at the head
        if (test(current)) {
            onRemove(current);
            this.popHead();
        }
    }

    public function remove(e : T)
    {
        if (e.next == e) {
            this.head = null;
        }
        else {
            if (e == this.head) {
                this.head = e.next;
            }
            e.prev.next = e.next;
            e.next.prev = e.prev;
        }
        e.prev = null;
        e.next = null;
        length -= 1;
    }
}
