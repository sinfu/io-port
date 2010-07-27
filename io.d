
import std.perf;
import core.stdc.stdio;

void main()
{
    auto pc = new PerformanceCounter;

    pc.start;
    size_t nlines = 0;
    foreach (i; 0 .. 1000)
    {
        auto file = File!(IODirection.input)(__FILE__);
        auto uport = openUTF8TextInputPort(file);

        foreach (line; uport.byLine)
            ++nlines;
    }
    pc.stop;

    printf("%g line/sec\n", nlines / (1.e-6 * pc.microseconds));
}


//----------------------------------------------------------------------------//

import std.algorithm;
import std.array;
import std.conv;
import std.range;
import std.string : toStringz;

import core.stdc.errno;
import core.stdc.stdio;

import core.sys.posix.fcntl;
import core.sys.posix.unistd;


enum IODirection
{
    input,
    output,
    both,
}


version (Posix)
@system struct File(IODirection direction_)
{
    this(in char[] path)
    {
        static immutable int[IODirection.max + 1] MODE =
            [
                IODirection.input : O_RDONLY,
                IODirection.output: O_WRONLY,
                IODirection.both  : O_RDWR
            ];

        context_        = new Context;
        context_.handle = .open(path.toStringz(), MODE[direction_]);
        if (context_.handle < 0)
        {
            switch (errno)
            {
              default:
                throw new Exception("open");
            }
            assert(0);
        }
    }

    this(this)
    {
        if (context_)
            ++context_.refCount;
    }

    ~this()
    {
        if (context_ && --context_.refCount == 0)
            close();
    }


    //----------------------------------------------------------------//
    // Device Handle Primitives
    //----------------------------------------------------------------//

    /*
     *
     */
    @property bool isOpen() const nothrow
    {
        return context_ && context_.handle >= 0;
    }


    /*
     *
     */
    void close()
    {
        // Lock
        if (context_.handle != -1)
        {
            while (.close(context_.handle) == -1)
            {
                switch (errno)
                {
                  case EINTR:
                    continue;

                  default:
                    throw new Exception("close");
                }
                assert(0);
            }
            context_.handle = -1;
            context_        = null;
        }
    }


    //----------------------------------------------------------------//
    // IO Device Primitives
    //----------------------------------------------------------------//

  static if ( direction_ == IODirection.input ||
              direction_ == IODirection.both )
    size_t read(ubyte[] buffer)
    {
        // Lock
        ssize_t bytesRead;

        while ((bytesRead = .read(context_.handle, buffer.ptr, buffer.length)) == -1)
        {
            switch (errno)
            {
              case EINTR:
                continue;

              default:
                throw new Exception("read");
            }
            assert(0);
        }
        return to!size_t(bytesRead);
    }

    /*
     * Writes upto $(D buffer.length) bytes of data from $(D buffer).
     */
  static if ( direction_ == IODirection.output ||
              direction_ == IODirection.both )
    size_t write(in ubyte[] buffer)
    {
        // Lock
        ssize_t bytesWritten;

        while ((bytesWritten = .write(context_.handle, buffer.ptr, buffer.length)) == -1)
        {
            switch (errno)
            {
              case EINTR:
                continue;

              default:
                throw new Exception("write");
            }
            assert(0);
        }
        return to!size_t(bytesWritten);
    }


    //----------------------------------------------------------------//
    // Seekable Device Primitives
    //----------------------------------------------------------------//

    /*
     *
     */
    void seek(long pos, bool relative = false)
    {
        immutable whence = (relative ? SEEK_CUR : SEEK_SET);

        if (.lseek(context_.handle, to!fpos_t(pos), SEEK_SET) == -1)
        {
            switch (errno)
            {
              case EOVERFLOW:
                throw new Exception("seek overflow");

              default:
                throw new Exception("seek");
            }
            assert(0);
        }
    }


    /*
     *
     */
    @property ulong position() const
    {
        immutable pos = .lseek(context_.handle, 0, SEEK_CUR);
        if (pos == -1)
        {
            switch (errno)
            {
              default:
                throw new Exception("position");
            }
            assert(0);
        }
        return to!ulong(pos);
    }


    /*
     * Returns the size of the file.
     */
    @property ulong size() const
    {
        immutable size = .lseek(context_.handle, 0, SEEK_END);
        if (size == -1)
        {
            switch (errno)
            {
              default:
                throw new Exception("size");
            }
            assert(0);
        }
        return to!ulong(size);
    }


    //----------------------------------------------------------------//
private:
    struct Context
    {
        int handle;
        int refCount = 1;
    }
    Context* context_;
}


//----------------------------------------------------------------------------//

struct InputBuffer(Device)
{
    this(Device device, size_t bufferSize)
    {
        context_        = new Context;
        context_.buffer = new ubyte[](bufferSize);
        swap(device_, device);
    }

    void opAssign(typeof(this) rhs)
    {
        swap(this, rhs);
    }


    //----------------------------------------------------------------//

    void fill()
    {
        with (*context_)
        {
            if (bufferStart == bufferEnd)
                bufferStart = bufferEnd = 0;

            if (bufferEnd < buffer.length)
                bufferEnd += device_.read(buffer[bufferEnd .. $]);
        }
    }

    ubyte[] data()
    {
        with (*context_)
            return buffer[bufferStart .. bufferEnd];
    }

    void skip(size_t count)
    {
        context_.bufferStart += count;
    }


    //----------------------------------------------------------------//

    @property ref Device device()
    {
        return device_;
    }

    static if (is(typeof(Device.seek) == function))
    {
        void seek(long step)
        {
            if (step == 0)
                return;

            with (*context_)
            {
                if (step < 0)
                {
                    if (bufferStart + step >= 0)
                        bufferStart += step;
                    else
                        resetAt(position + step);
                }
                else
                {
                    if (bufferStart + step <= bufferEnd)
                        bufferStart += step;
                    else
                        resetAt(position + step);
                }
            }
        }

        private void resetAt(long pos)
        {
            device_.seek(pos);
            context_.bufferStart = 0;
            context_.bufferEnd   = 0;
            fill();
        }

        @property ulong position()
        {
            return device_.position - data.length;
        }
    }


    //----------------------------------------------------------------//
private:
    struct Context
    {
        ubyte[] buffer;
        size_t  bufferStart;
        size_t  bufferEnd;
    }
    Device   device_;
    Context* context_;
}

unittest
{
    static struct ZeroDevice
    {
        size_t read(ubyte[] buffer)
        {
            buffer[] = 0;
            return buffer.length;
        }
    }
    ZeroDevice device;

    auto buffer = InputBuffer!ZeroDevice(device, 512);
    buffer.fill();
    buffer.skip(128);
    assert(buffer.buffer.length == 512 - 128);
}


//----------------------------------------------------------------------------//

/*
 * Mixin to implement lazy input range
 */
template implementLazyInput(E)
{
    @property bool empty()
    {
        if (context_.wantNext)
            popFrontLazy();
        return context_.empty;
    }

    @property ref E front()
    {
        if (context_.wantNext)
            popFrontLazy();
        return context_.front;
    }

    void popFront()
    {
        if (context_.wantNext)
            popFrontLazy();
        context_.wantNext = true;
    }

private:
    void reset()
    {
        context_ = new Context;
    }

    void popFrontLazy()
    {
        context_.wantNext = false;
        context_.empty    = !readNext(context_.front);
    }

    struct Context
    {
        E    front;
        bool empty;
        bool wantNext = true;
    }
    Context* context_;
}

unittest
{
    static struct Test
    {
        private int max_;

        this(int max)
        {
            max_ = max;
            reset();
        }

        mixin implementLazyInput!(int);

        private bool readNext(ref int front)
        {
            if (max_ < 0)
                return false;
            front = --max_;
            return true;
        }
    }
    auto r = Test(4);
    assert(r.front == 3); r.popFront;
    assert(r.front == 2); r.popFront;
    assert(r.front == 1); r.popFront;
    assert(r.front == 0); r.popFront;
    assert(r.empty);
}


//----------------------------------------------------------------------------//

BinaryPort!Device openBinaryPort(Device)(Device device, size_t bufferSize = 4096)
{
    return typeof(return)(device, bufferSize);
}

struct BinaryPort(Device)
{
    this(Device device, size_t bufferSize)
    {
        context_        = new Context;
        context_.buffer = new ubyte[](bufferSize);
        swap(device_, device);
    }

    void opAssign(typeof(this) rhs)
    {
        swap(this, rhs);
    }


    //----------------------------------------------------------------//

    @property ByVariableChunk byVariableChunk()
    {
        return ByVariableChunk(this);
    }

    struct ByVariableChunk
    {
        private this(BinaryPort port)
        {
            reset();
            swap(port_, port);
        }

        void opAssign(typeof(this) rhs)
        {
            swap(this, rhs);
        }

        // implement input range primitives
        mixin implementLazyInput!(ubyte[]);

    private:
        bool readNext(ref ubyte[] front)
        {
            with (*port_.context_)
            {
                if (bufferStart == bufferEnd)
                {
                    if (!port_.fetch())
                        return false;
                }
                front       = buffer[bufferStart .. bufferEnd];
                bufferStart = bufferEnd;
            }
            return true;
        }

        BinaryPort port_;
    }


    //----------------------------------------------------------------//

    void readExact(ubyte[] store)
    {
        with (*context_)
        {
            if (store.length < bufferRem)
            {
                store[] = buffer[bufferStart .. bufferStart + store.length];
                return;
            }

            store[0 .. bufferRem] = buffer[bufferStart .. bufferEnd];
            store                 = store[bufferRem .. $];
            bufferStart = bufferEnd;

            while (store.length > 0)
                store = store[device_.read(store) .. $];
        }
    }

    T readValue(T)()
    {
        T store = void;
        readExact((cast(ubyte*) &store)[0 .. store.sizeof]);
        return store;
    }


    //----------------------------------------------------------------//
private:

    @property size_t bufferRem() const nothrow
    {
        return context_.bufferEnd - context_.bufferStart;
    }

    bool fetch()
    in
    {
        assert(bufferRem == 0);
    }
    body
    {
        with (*context_)
        {
            bufferEnd   = device_.read(buffer);
            bufferStart = 0;
            return bufferEnd > 0;
        }
    }


    //----------------------------------------------------------------//
private:
    static struct Context
    {
        ubyte[] buffer;
        size_t  bufferStart;
        size_t  bufferEnd;
    }
    Device   device_;
    Context* context_;
}


//----------------------------------------------------------------------------//

UTF8TextInputPort!Device openUTF8TextInputPort(Device)(Device device, size_t bufferSize = 2048)
{
    return typeof(return)(device, bufferSize);
}

@system struct UTF8TextInputPort(Device)
{
    private this(Device device, size_t bufferSize)
    {
        context_        = new Context;
        context_.buffer = new ubyte[](bufferSize);
        swap(device_, device);
    }

    void opAssign(typeof(this) rhs)
    {
        swap(this, rhs);
    }


    //----------------------------------------------------------------//

    @property ByLine byLine(string terminator = "\n")
    {
        return ByLine(this, terminator);
    }

    struct ByLine
    {
        private this(UTF8TextInputPort port, string terminator)
        {
            reset();
            terminator_ = terminator;
            swap(port_, port);
        }

        void opAssign(typeof(this) rhs)
        {
            swap(this, rhs);
        }

        mixin implementLazyInput!(const(char)[]);

    private:
        bool readNext(ref const(char)[] front)
        {
            char[] line  = null;
            size_t match = 0;

            with (*port_.context_) for (size_t cursor = bufferStart; ; ++cursor)
            {
                if (cursor == bufferEnd)
                {
                    // The terminator was not found in the current buffer.

                    // Concatenate the current buffer content to the result
                    // string buffer (line) anyway.
                    auto partial = cast(char[]) buffer[bufferStart .. cursor];

                    if (line.empty)
                        line  = partial.dup;
                    else
                        line ~= partial;

                    if (!port_.fetchNew())
                        break; // EOF
                    cursor = bufferStart;
                }

                assert(cursor <= bufferEnd);
                assert(match <= terminator_.length);

                if (buffer[cursor] == terminator_[match])
                    ++match;
                else
                    match = 0;

                if (match == terminator_.length)
                {
                    auto partial = cast(char[]) buffer[bufferStart .. cursor];

                    if (line.empty)
                        line  = partial;
                    else
                        line ~= partial;

                    // Chop the line out of the buffer.
                    bufferStart = cursor + 1;
                    break;
                }
            }
            return (front = line) !is null;
        }

        UTF8TextInputPort port_;
        string            terminator_;
    }


    //----------------------------------------------------------------//
private:

    @property size_t bufferRem() const nothrow
    {
        return context_.bufferEnd - context_.bufferStart;
    }

    bool fetch()
    in
    {
        assert(bufferRem == 0);
    }
    body
    {
        with (*context_)
        {
            bufferEnd   = device_.read(buffer);
            bufferStart = 0;
            return bufferEnd > 0;
        }
    }

    bool fetchNew()
    {
        with (*context_)
        {
            bufferStart = bufferEnd;
        }
        return fetch();
    }


    //----------------------------------------------------------------//
private:
    static struct Context
    {
        ubyte[] buffer;
        size_t  bufferStart;
        size_t  bufferEnd;
    }
    Device   device_;
    Context* context_;
}


