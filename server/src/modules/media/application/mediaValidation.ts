/** Bounded structural validation for supported ISO-BMFF audio and video objects. */
import { GetObjectCommand, type S3Client } from '@aws-sdk/client-s3';
import type { ArtifactType } from '@prisma/client';
import { config } from '../../../platform/config.js';
import { withDeadline } from '../../../platform/deadline.js';
import { ErrorCodes } from '../../../platform/http/errorCodes.js';
import { ApiError } from '../../../platform/http/errors.js';

const BOX_HEADER_BYTES = 8;
const EXTENDED_BOX_HEADER_BYTES = 16;
const MAX_TOP_LEVEL_BOXES = 64;
const MAX_BOX_DEPTH = 8;
const MAX_FTYP_BYTES = 4096;
// Long lesson recordings can carry substantial sample-table metadata. Keep
// validation bounded without rejecting ordinary multi-minute captures.
const MAX_MOOV_BYTES = 2 * 1024 * 1024;
const MAX_METADATA_BYTES = MAX_FTYP_BYTES + MAX_MOOV_BYTES;
const RANGE_WINDOW_BYTES = 64 * 1024;
const MAX_RANGE_CACHE_BYTES = MAX_METADATA_BYTES + RANGE_WINDOW_BYTES;

type Box = { type: string; start: number; headerSize: number; end: number; dataStart: number };
type TopLevelMetadata = {
  ftyp?: Uint8Array;
  moov?: Uint8Array;
  hasMdat: boolean;
  metadataBytes: number;
};

export function expectedContentType(type: ArtifactType): string {
  return type === 'video' ? 'video/mp4' : 'audio/m4a';
}

/** Fetch declared ftyp/moov metadata and skip mdat payloads by declared size. */
export async function assertSupportedMediaContainer(
  s3: S3Client,
  key: string,
  type: ArtifactType,
  contentLength: number | undefined,
  options: { abortSignal?: AbortSignal; timeoutMs?: number } = {}
) {
  if (!contentLength || contentLength < BOX_HEADER_BYTES) throw unsupportedContainerError();
  const validate = (abortSignal: AbortSignal) =>
    readTopLevelMetadata(new RangeReader(s3, key, contentLength, abortSignal), contentLength);
  const metadata = options.abortSignal
    ? await validate(options.abortSignal)
    : await withDeadline(
        validate,
        options.timeoutMs ?? config.dependencyTimeoutMs,
        'S3 media probe'
      );
  if (!metadata.ftyp || !metadata.moov || !metadata.hasMdat) throw unsupportedContainerError();
  if (!hasSupportedFtyp(metadata.ftyp, type) || !hasExpectedTrack(metadata.moov, type)) {
    throw unsupportedContainerError();
  }
}

async function readTopLevelMetadata(reader: RangeReader, contentLength: number) {
  let offset = 0;
  const metadata: TopLevelMetadata = { hasMdat: false, metadataBytes: 0 };

  for (let count = 0; offset < contentLength && count < MAX_TOP_LEVEL_BOXES; count += 1) {
    const header = await reader.read(
      offset,
      Math.min(contentLength - 1, offset + EXTENDED_BOX_HEADER_BYTES - 1)
    );
    const box = parseBox(header, 0, header.length, contentLength - offset);
    if (!box) throw unsupportedContainerError();
    const absoluteEnd = offset + box.end;
    await collectTopLevelBox(reader, offset, absoluteEnd, box, metadata);
    offset = absoluteEnd;
  }

  if (offset !== contentLength) throw unsupportedContainerError();
  return metadata;
}

async function collectTopLevelBox(
  reader: RangeReader,
  offset: number,
  absoluteEnd: number,
  box: Box,
  metadata: TopLevelMetadata
) {
  if (box.type === 'mdat') {
    if (box.end <= box.headerSize) throw unsupportedContainerError();
    metadata.hasMdat = true;
    return;
  }
  const cap = box.type === 'ftyp' ? MAX_FTYP_BYTES : box.type === 'moov' ? MAX_MOOV_BYTES : 0;
  if (cap === 0) return;
  if (box.end > cap || metadata.metadataBytes + box.end > MAX_METADATA_BYTES) {
    throw unsupportedContainerError();
  }
  const bytes = await reader.read(offset, absoluteEnd - 1);
  if (box.type === 'ftyp') {
    if (metadata.ftyp) throw unsupportedContainerError();
    metadata.ftyp = bytes;
  } else {
    if (metadata.moov) throw unsupportedContainerError();
    metadata.moov = bytes;
  }
  metadata.metadataBytes += bytes.length;
}

function hasSupportedFtyp(ftyp: Uint8Array, type: ArtifactType): boolean {
  const box = parseBox(ftyp, 0, ftyp.length, ftyp.length);
  return Boolean(box && box.end === ftyp.length && hasSupportedFtypBox(ftyp, box, type));
}

function hasSupportedFtypBox(data: Uint8Array, box: Box, type: ArtifactType): boolean {
  if (box.type !== 'ftyp' || box.end - box.dataStart < 8 || (box.end - box.dataStart - 8) % 4 !== 0)
    return false;
  const brands = [readFourCc(data, box.dataStart)];
  for (let offset = box.dataStart + 8; offset < box.end; offset += 4)
    brands.push(readFourCc(data, offset));
  const audioBrands = new Set(['M4A ', 'M4B ', 'M4P ']);
  const videoBrands = new Set(['isom', 'iso2', 'mp41', 'mp42', 'avc1', 'hvc1']);
  return type === 'audio'
    ? brands.some((brand) => audioBrands.has(brand))
    : brands.some((brand) => videoBrands.has(brand));
}

function hasExpectedTrack(moov: Uint8Array, type: ArtifactType): boolean {
  const box = parseBox(moov, 0, moov.length, moov.length);
  return Boolean(box && box.end === moov.length && hasExpectedTrackBox(moov, box, type));
}

function hasExpectedTrackBox(data: Uint8Array, moov: Box, type: ArtifactType): boolean {
  if (moov.type !== 'moov') return false;
  const tracks = childBoxes(data, moov, 1).filter((box) => box.type === 'trak');
  if (tracks.length === 0) return false;
  const handlers = tracks.map((track) => handlerTypeForTrack(data, track));
  if (handlers.some((handler) => handler === null)) return false;
  const resolved = handlers as string[];
  return type === 'audio'
    ? resolved.includes('soun') && !resolved.includes('vide')
    : resolved.includes('vide');
}

function handlerTypeForTrack(data: Uint8Array, track: Box): string | null {
  const mdia = childBoxes(data, track, 2).filter((box) => box.type === 'mdia');
  const mdiaBox = mdia.length === 1 ? mdia[0] : undefined;
  if (!mdiaBox) return null;
  const hdlr = childBoxes(data, mdiaBox, 3).filter((box) => box.type === 'hdlr');
  const hdlrBox = hdlr.length === 1 ? hdlr[0] : undefined;
  if (!hdlrBox || hdlrBox.end - hdlrBox.dataStart < 12) return null;
  return readFourCc(data, hdlrBox.dataStart + 8);
}

function childBoxes(data: Uint8Array, parent: Box, depth: number): Box[] {
  return parseChildren(data, parent.dataStart, parent.end, depth);
}

function parseChildren(data: Uint8Array, start: number, end: number, depth: number): Box[] {
  if (depth > MAX_BOX_DEPTH) throw new Error('box nesting exceeds limit');
  const boxes: Box[] = [];
  for (let offset = start; offset < end; ) {
    if (boxes.length >= MAX_TOP_LEVEL_BOXES) throw new Error('box count exceeds limit');
    const box = parseBox(data, offset, end, end - offset);
    if (!box) throw new Error('invalid box');
    boxes.push(box);
    offset = box.end;
  }
  if (boxes.length === 0 || boxes.at(-1)!.end !== end) throw new Error('truncated box sequence');
  return boxes;
}

function parseBox(
  data: Uint8Array,
  start: number,
  availableEnd: number,
  remainingBytes: number
): Box | null {
  if (start < 0 || start + BOX_HEADER_BYTES > availableEnd || remainingBytes < BOX_HEADER_BYTES)
    return null;
  const size32 = readUint32(data, start);
  const type = readFourCc(data, start + 4);
  let headerSize = BOX_HEADER_BYTES;
  let size: number;
  if (size32 === 1) {
    if (
      start + EXTENDED_BOX_HEADER_BYTES > availableEnd ||
      remainingBytes < EXTENDED_BOX_HEADER_BYTES
    )
      return null;
    const extended = readUint64(data, start + BOX_HEADER_BYTES);
    if (extended > BigInt(Number.MAX_SAFE_INTEGER)) return null;
    size = Number(extended);
    headerSize = EXTENDED_BOX_HEADER_BYTES;
  } else if (size32 === 0) {
    size = remainingBytes;
  } else {
    size = size32;
  }
  if (size < headerSize || size > remainingBytes) return null;
  return { type, start, headerSize, end: start + size, dataStart: start + headerSize };
}

class RangeReader {
  private cacheStart = 0;
  private cache: Uint8Array<ArrayBufferLike> = new Uint8Array();

  constructor(
    private readonly s3: S3Client,
    private readonly key: string,
    private readonly contentLength: number,
    private readonly abortSignal: AbortSignal
  ) {}

  async read(start: number, end: number): Promise<Uint8Array> {
    const cacheEnd = this.cacheStart + this.cache.length - 1;
    if (start >= this.cacheStart && end <= cacheEnd) return this.slice(start, end);

    if (this.cache.length > 0 && start >= this.cacheStart && start <= cacheEnd + 1) {
      const tail = await this.fetch(cacheEnd + 1, end);
      const combined = concatBytes(this.cache, tail);
      if (combined.length <= MAX_RANGE_CACHE_BYTES) this.cache = combined;
      if (end <= this.cacheStart + combined.length - 1) {
        return combined.slice(start - this.cacheStart, end - this.cacheStart + 1);
      }
    }

    const fetchEnd = Math.min(
      this.contentLength - 1,
      Math.max(end, start + RANGE_WINDOW_BYTES - 1)
    );
    this.cacheStart = start;
    this.cache = await this.fetch(start, fetchEnd);
    if (end >= this.cacheStart + this.cache.length) throw unsupportedContainerError();
    return this.slice(start, end);
  }

  private slice(start: number, end: number) {
    return this.cache.slice(start - this.cacheStart, end - this.cacheStart + 1);
  }

  private async fetch(start: number, end: number): Promise<Uint8Array> {
    if (start > end) return new Uint8Array();
    this.abortSignal.throwIfAborted();
    const response = await this.s3.send(
      new GetObjectCommand({
        Bucket: config.s3.bucket,
        Key: this.key,
        Range: `bytes=${start}-${end}`,
      }),
      { abortSignal: this.abortSignal }
    );
    const body = response.Body;
    let bytes: Uint8Array;
    if (body instanceof Uint8Array) bytes = body;
    else if (body && typeof body === 'object' && 'transformToByteArray' in body) {
      bytes = await (
        body as { transformToByteArray: () => Promise<Uint8Array> }
      ).transformToByteArray();
    } else {
      throw new Error('S3 media probe returned no readable body');
    }
    this.abortSignal.throwIfAborted();
    if (bytes.length !== end - start + 1) {
      throw new Error('S3 media probe returned an unexpected range length');
    }
    return bytes;
  }
}

function concatBytes(first: Uint8Array, second: Uint8Array) {
  const combined = new Uint8Array(first.length + second.length);
  combined.set(first);
  combined.set(second, first.length);
  return combined;
}

function readUint32(data: Uint8Array, offset: number): number {
  return new DataView(data.buffer, data.byteOffset, data.byteLength).getUint32(offset, false);
}

function readUint64(data: Uint8Array, offset: number): bigint {
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return (BigInt(view.getUint32(offset, false)) << 32n) | BigInt(view.getUint32(offset + 4, false));
}

function readFourCc(data: Uint8Array, offset: number): string {
  return String.fromCharCode(...data.slice(offset, offset + 4));
}

function unsupportedContainerError() {
  return new ApiError(
    409,
    ErrorCodes.UPLOAD_INVALID,
    'Uploaded object is not a supported media container'
  );
}
