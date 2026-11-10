// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// One record's bytes, shared by both second tiers so a record written by one has
// the shape the other reads:
//
//   tag:u8 | klen:i32 | key | vlen:i32 | value
//
// Little-endian, and the tag is there because a file that only appends needs a
// second record kind (a delete) in the same stream.

///|
/// Encodes one record. The key and value codecs are the caller's, so the bytes
/// are the same whatever the medium is.
pub fn[K, V] encode_record(
  encode_key : (K) -> Bytes,
  encode_value : (V) -> Bytes,
  key : K,
  value : V,
) -> Bytes {
  let buf = @buffer.Buffer()
  let kb = encode_key(key)
  let vb = encode_value(value)
  buf.write_byte(record_put)
  buf.write_int_le(kb.length())
  buf.write_bytes(kb.exact_view())
  buf.write_int_le(vb.length())
  buf.write_bytes(vb.exact_view())
  buf.to_bytes()
}

///|
/// Decodes one record. `None` means the bytes are not a record, or a codec
/// refused its half of it.
pub fn[K, V] decode_record(
  view : BytesView,
  decode_key : (Bytes) -> K?,
  decode_value : (Bytes) -> V?,
) -> (K, V)? {
  let total = view.length()
  if total < 5 || view.at(0).to_int() != 1 {
    return None
  }
  let klen = read_i32_le(view, 1)
  if klen < 0 || 5 + klen > total {
    return None
  }
  let vstart = 5 + klen
  if vstart + 4 > total {
    return None
  }
  let vlen = read_i32_le(view, vstart)
  if vlen < 0 || vstart + 4 + vlen > total {
    return None
  }
  let key_bytes = view.exact_view(start=5, end=5 + klen).to_owned()
  let value_bytes = view
    .exact_view(start=vstart + 4, end=vstart + 4 + vlen)
    .to_owned()
  match decode_key(key_bytes) {
    Some(key) =>
      match decode_value(value_bytes) {
        Some(value) => Some((key, value))
        None => None
      }
    None => None
  }
}

///|
/// The tag of a record that carries a key and a value.
pub let record_put : Byte = b'\x01'

///|
/// The tag of a record that carries a key alone: the file tier's delete.
pub let record_del : Byte = b'\x02'

///|
/// Reads a little-endian `i32` at `off`.
fn read_i32_le(view : BytesView, off : Int32) -> Int32 {
  let b0 = view.at(off).to_int()
  let b1 = view.at(off + 1).to_int()
  let b2 = view.at(off + 2).to_int()
  let b3 = view.at(off + 3).to_int()
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

///|
/// Encodes a delete record: the file tier's way of marking a record dead without
/// rewriting the file.
pub fn[K] encode_delete(encode_key : (K) -> Bytes, key : K) -> Bytes {
  let buf = @buffer.Buffer()
  let kb = encode_key(key)
  buf.write_byte(record_del)
  buf.write_int_le(kb.length())
  buf.write_bytes(kb.exact_view())
  buf.to_bytes()
}
