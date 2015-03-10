﻿module libhttp2.buffers;

import libhttp2.types;
import std.algorithm : max;
import core.exception : onOutOfMemoryError;
import std.c.string : memcpy;

struct Buffer
{
	/// This points to the beginning of the buffer. The effective range of buffer is [begin, end).
	ubyte* begin;
	/// This points to the memory one byte beyond the end of the buffer.
	ubyte* end;
	/// The position indicator for effective start of the buffer. pos <= last must be hold.
	ubyte* pos;
	/// The position indicator for effective one beyond of the end of the buffer. last <= end must be hold.
	ubyte* last;
	/// Mark arbitrary position in buffer [begin, end)
	ubyte* mark;

	T[] opSlice() { return pos[0 .. length]; }

	@property int length() {
		return cast(int)(last - pos);
	}

	@property int available() {
		return cast(int)(end - last);
	}

	@property int markAvailable() {
		return cast(int)(mark - last);
	}

	@property int capacity() {
		return cast(int)(end - begin);
	}

	@property int posOffset() {
		return cast(int)(pos - begin);
	}
	@property int offset() {
		return cast(int) (last - begin);
	}

	void shiftRight(size_t amount) {
		pos += amount;
		last += amount;
	}

	void shiftLeft(size_t amount) {
		pos -= amount;
		last -= amount;
	}

	void free()
	{
		if (!begin) return;
		
		Mem.free(begin[0 .. end - begin]);
		buf.begin = null;
	}
	
	/*
	 * Extends buffer so that capacity() returns at least
	 * |new_cap|. If extensions took place, buffer pointers in |buf| will
	 * change.
	 */
	void reserve(size_t new_cap)
	{
		if (!new_cap) return;

		ubyte[] new_buf;
		size_t cap;
		
		cap = capacity;
		
		if (cap >= new_cap) {
			return 0;
		}
		
		new_cap = max(new_cap, cap * 2);
		
		if (begin)
			new_buf = Mem.realloc(begin[0 .. end - begin], new_cap);
		else
			new_buf = Mem.alloc!(ubyte[])(new_cap);
		
		ubyte* ptr = new_buf.ptr;
		
		pos = ptr + (pos - begin);
		last = ptr + (last - begin);
		mark = ptr + (mark - begin);
		begin = ptr;
		end = ptr + new_cap;
		
		return 0;
	}
	
	/// Resets pos, last, mark member of |buf| to buf.begin.
	void reset()
	{
		pos = last = mark = begin;
	}
	
	/*
	 * Initializes Buffer using supplied buffer |buf|. Semantically, 
	 * the application should not call *_reserve() or free() functions.
	 */
	this(ubyte[] buf) {
		owner = true;
		begin = pos = last = mark = begin;
		end = begin + len;
	}		
	
	/*
	 * Initializes the |buf| and allocates at least |initial| bytes of
	 * memory.
	 */
	this(size_t initial = 0) {
		begin = null;
		end = null;
		pos = null;
		last = null;
		mark = null;
		reserve(initial);
	}

}

class Buffers {

	class Chain {
		Buffer buf;
		Chain next;
		static Chain opCall(size_t chunk_length = 0)
		{
			Chain ret;
			chain = Mem.alloc!Chain();
			scope(failure) Mem.free(chain);
			
			chain.next = null;			
			chain.buf = Buffer(chunk_length);

			return ret;
		}

		void free() {
			buf.free();
			Mem.free(chain);
		}
	}

	/// Points to the first buffer
	Chain head;
	/// Buffer pointer where write occurs.
	Chain cur;
	/// The buffer capacity of each Buffer
	size_t chunk_length;
	/// The maximum number of `Chain`s
	size_t max_chunk;
	/// The number of `Chain`s allocated
	size_t chunk_used;
	/// The number of `Chain`s to keep on reset
	size_t chunk_keep;
	/// pos offset from begin in each buffers. On initialization and reset, buf.pos and buf.last are positioned at buf.begin + offset.
	size_t offset;

	bool dontFree;

	/// This is the same as calling init2 with the given arguments and offset = 0.
	this(size_t _chunk_length, size_t _max_chunk) {
		this(_chunk_length, _max_chunk, _max_chunk, 0);
	}

	/// This is the same as calling init3 with the given arguments and chunk_keep = max_chunk.
	this(size_t _chunk_length, size_t _max_chunk, size_t _offset)
	{
		this(_chunk_length, _max_chunk, _max_chunk, _offset);
	}

	/**
	 * Initializes Buffers. Each buffer size is given in the
	 * |chunk_length|.  The maximum number of buffers is given in the
	 * |max_chunk|.  On reset, first |chunk_keep| buffers are kept and
	 * remaining buffers are deleted.  Each buffer will have bufs.pos and
	 * bufs.last shifted to left by |offset| bytes on creation and reset.
	 *
	 * This function allocates first buffer.  bufs.head and bufs.cur
	 * will point to the first buffer after this call.
	 */
	this(size_t _chunk_length, size_t _max_chunk, size_t _chunk_keep, size_t _offset) 
	in { assert(_chunk_keep == 0 || _max_chunk < _chunk_keep || _chunk_length < _offset, "Invalid Arguments"); }
	body
	{
		Chain chain = Chain(chunk_length);

		offset = _offset;
		
		head = chain;
		cur = head;
		
		cur.buf.shiftRight(offset);
		
		chunk_length = _chunk_length;
		chunk_used = 1;
		max_chunk = _max_chunk;
		chunk_keep = _chunk_keep;
	}

	/*
	 * Initializes Buffers using supplied buffer |buf|.
	 * The first buffer bufs.head uses buffer |begin|.  The buffer size
	 * is fixed and no allocate extra chunk buffer is allocated.  In other
	 * words, max_chunk = chunk_keep = 1. 
	 */
	this(ubyte[] buf)
	{
		Chain chain = Chain();

		chain.next = null;		
		chain.buf = Buffer(buf);

		dontFree = true;
		offset = 0;		
		head = chain;
		cur = head;		
		chunk_length = buf.length;
		chunk_used = 1;
		max_chunk = 1;
		chunk_keep = 1;
	}

	/// Frees any related resources
	void free()
	{
		Chain chain;
		Chain next_chain;
		
		if (!head) return;

		if (dontFree) {
			Mem.free(bufs.head);
			bufs.head = null;
			return;
		}
		
		for (chain = head; chain;) {
			next_chain = chain.next;			
			chain.free();			
			chain = next_chain;
		}
		
		head = null;
	}	

	/*
	 * Reallocates internal buffer using |chunk_length|.  The max_chunk,
	 * chunk_keep and offset do not change.  After successful allocation
	 * of new buffer, previous buffers are deallocated without copying
	 * anything into new buffers.  chunk_used is reset to 1.
	 *
	 * This function returns 0 if it succeeds, or one of the following
	 * negative error codes:
	 *
	 * ErrorCode.NOMEM
	 *     Out of memory.
	 * ErrorCode.INVALID_ARGUMENT
	 *     chunk_length < offset
	 */
	ErrorCode realloc(size_t _chunk_length)
	in { assert(chunk_length < bufs.offset, "Invalid Arguments"); }
	body {
		Chain chain = Chain(chunk_length);
		
		free();
		
		head = chain;
		cur = head;
		
		cur.buf.shiftRight(offset);
		
		chunk_length = _chunk_length;
		chunk_used = 1;
	}

	/*
	 * Appends the |data| of length |len| to the |bufs|. The write starts
	 * at bufs.cur.buf.last. A new buffers will be allocated to store
	 * all data.
	 *
	 * This function returns 0 if it succeeds, or one of the following
	 * negative error codes:
	 *
	 * ErrorCode.NOMEM
	 *     Out of memory.
	 * ErrorCode.BUFFER_ERROR
	 *     Out of buffer space.
	 */
	ErrorCode add(in ubyte[] data)
	{
		ErrorCode rv;
		size_t nwrite;
		Buffer* buf;
		const ubyte *p;
		int len = cast(int)data.length;
		if (bufs.available < len) {
			return ErrorCode.BUFFER_ERROR;
		}
		
		p = data.ptr;
		
		while (len) {
			buf = &bufs.cur.buf;
			
			nwrite = cast(size_t) min(buf.available, len);
			if (nwrite == 0) {
				rv = allocChain();
				if (rv != 0) {
					return rv;
				}
				continue;
			}
			
			buf.last = memcpy(buf.last, p, nwrite);
			p += len;
			len -= nwrite;
		}
		
		return 0;
	}

	/*
	 * Appends a single byte |b| to the Buffers. The write starts at
	 * cur.buf.last. A new buffers will be allocated to store all
	 * data.
	 *
	 * This function returns 0 if it succeeds, or one of the following
	 * negative error codes:
	 *
	 * ErrorCode.NOMEM
	 *     Out of memory.
	 * ErrorCode.BUFFER_ERROR
	 *     Out of buffer space.
	 */
	ErrorCode add(ubyte b)
	{
		int rv;
		
		rv = ensureAddByte();
		if (rv != 0) 
			return rv;

		
		*cur.buf.last++ = b;
		
		return 0;
	}

	/*
	 * Behaves like addb(), but this does not update
	 * buf.last pointer.
	 */
	ErrorCode addHold(ubyte b)
	{
		int rv;
		
		rv = ensureAddByte();
		if (rv != 0) {
			return rv;
		}
		
		*cur.buf.last = b;
		
		return 0;
	}

	void fastAdd(ubyte b) {
		*cur.buf.last++ = b;
	}

	void fastAddHold(ubyte b) {
		*cur.buf.last = b;
	}
		
	/*
	 * Performs bitwise-OR of |b| at cur.buf.last. A new buffers
	 * will be allocated if necessary.
	 *
	 * This function returns 0 if it succeeds, or one of the following
	 * negative error codes:
	 *
	 * ErrorCode.NOMEM
	 *     Out of memory.
	 * ErrorCode.BUFFER_ERROR
	 *     Out of buffer space.
	 */
	ErrorCode or(ubyte b)
	{
		int rv;
		
		rv = ensureAddByte();
		if (rv != 0) {
			return rv;
		}
		
		*cur.buf.last++ |= b;
		
		return 0;
	}

	/*
	 * Behaves like orb(), but does not update buf.last
	 * pointer.
	 */
	ErrorCode orHold(ubyte b)
	{
		int rv;
		
		rv = ensureAddByte();
		if (rv != 0) {
			return rv;
		}
		
		*cur.buf.last |= b;
		
		return 0;
	}

	void fastOr(ubyte b) {
		*cur.buf.last++ |= b;
	}

	void fastOrHold(ubyte b) {
		*cur.buf.last |= b;
	}

	/*
	 * Copies all data stored in Buffers to the contagious buffer.  This
	 * function allocates the contagious memory to store all data in
	 * Buffers and assigns it to |*out|.
	 */
	ubyte[] remove()
	{
		size_t len;
		Chain chain;
		Buffer* buf;
		ubyte[] res;
		Buffer resbuf;
		
		len = 0;
		
		for (chain = head; chain; chain = chain.next) {
			len += chain.buf.length;
		}
		
		if (!len) 
			res = null;
		else 
			res = Mem.alloc!(ubyte[])(len);
		
		resbuf = Buffer(res);
		
		for (chain = head; chain; chain = chain.next) {
			buf = &chain.buf;
			
			if (resbuf.last) {
				resbuf.last = memcpy(resbuf.last, buf.pos, buf.length);
			}
			
			buf.reset();
			chain.buf.shiftRight(offset);
		}
		
		cur = head;
		
		return res;
	}


	/*
	 * Resets Buffers and makes the buffers empty.
	 */
	void reset()
	{
		Chain chain;
		Chain ci;
		size_t k;
		
		k = chunk_keep;
		
		for (ci = head; ci; ci = ci.next) {
			ci.buf.reset();
			ci.buf.shiftRight(offset);
			
			if (--k == 0) {
				break;
			}
		}
		
		if (ci) {
			chain = ci.next;
			ci.next = null;
			
			for (ci = chain; ci;) {
				chain = ci.next;
				
				ci.free();
				
				ci = chain;
			}
			
			chunk_used = chunk_keep;
		}
		
		cur = head;
	}

	/*
	 * Moves cur to cur.next.  If resulting cur is
	 * null, this function allocates new buffers and cur points to
	 * it.
	 *
	 * This function returns 0 if it succeeds, or one of the following
	 * negative error codes:
	 *
	 * ErrorCode.NOMEM
	 *     Out of memory
	 * ErrorCode.BUFFER_ERROR
	 *     Out of buffer space.
	 */
	ErrorCode advance() { return allocChain(); }

	/* Sets cur to head */
	void rewind() {
		cur = head;
	}

	
	/*
	 * Move cur, from the current position, using next member, to
	 * the last buf which has length > 0 without seeing buf
	 * which satisfies length == 0.  If cur.buf.length == 0 or cur.next is null,
	 * cur is unchanged.
	 */
	void seekLastPresent()
	{
		Chain ci;
		
		for (ci = cur; ci; ci = ci.next) {
			if (ci.buf.length == 0) {
				return;
			} else {
				cur = ci;
			}
		}
	}

	/*
	 * Returns true if cur.next is not empty.
	 */
	bool nextPresent()
	{
		Chain chain;
		
		chain = cur.next;
		
		return chain && chain.buf.length;
	}

	int curAvailable() {
		return cur.buf.available();
	}

	@property int length() const
	{
		Chain ci;
		int len;
		
		len = 0;
		for (ci = head; ci; ci = ci.next) {
			len += ci.buf.length;
		}
		
		return len;
	}

private:
	@property int available() const {
		return cur.buf.available + (chunk_length - offset) * (max_chunk - chunk_used);

	}

	ErrorCode ensureAddByte()
	{
		int rv;
		Buffer* buf;
		
		buf = &cur.buf;
		
		if (buf.available >= 1) {
			return 0;
		}
		
		rv = allocChain();
		if (rv != 0)
			return rv;		
		return 0;
	}

	ErrorCode allocChain() {
		Chain chain;
		
		if (cur.next) {
			cur = cur.next;
			return 0;
		}
		
		if (max_chunk == chunk_used)
			return ErrorCode.BUFFER_ERROR;

		chain = Chain(chunk_length);
		
		DEBUGF(fprintf(stderr,
				"new buffer %zu bytes allocated for bufs %p, used %zu\n",
				chunk_length, this, chunk_used));
		
		++chunk_used;
		
		cur.next = chain;
		cur = chain;		
		cur.buf.shiftRight(offset);
		
		return 0;
	}

}