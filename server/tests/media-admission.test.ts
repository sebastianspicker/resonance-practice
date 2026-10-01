import { GetObjectCommand } from '@aws-sdk/client-s3';
import { describe, expect, it } from 'vitest';
import { assertSupportedMediaContainer } from '../src/modules/media/application/mediaValidation.js';
import { ApiError } from '../src/platform/http/errors.js';

function box(type: string, payload: Uint8Array = new Uint8Array(), extended = false): Uint8Array {
  const header = new Uint8Array(extended ? 16 : 8);
  const view = new DataView(header.buffer);
  if (extended) {
    view.setUint32(0, 1);
    view.setUint32(8, 0);
    view.setUint32(12, header.length + payload.length);
  } else {
    view.setUint32(0, header.length + payload.length);
  }
  header.set(Buffer.from(type), 4);
  return join(header, payload);
}

function join(...parts: Uint8Array[]): Uint8Array {
  const output = new Uint8Array(parts.reduce((length, part) => length + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    output.set(part, offset);
    offset += part.length;
  }
  return output;
}

function ftyp(major: string, compatible: string): Uint8Array {
  return box('ftyp', join(Buffer.from(major), new Uint8Array(4), Buffer.from(compatible)));
}

function hdlr(handler: string): Uint8Array {
  return box('hdlr', join(new Uint8Array(8), Buffer.from(handler)));
}

function fixture(type: 'audio' | 'video'): Uint8Array {
  const handler = type === 'audio' ? 'soun' : 'vide';
  const brand = type === 'audio' ? 'M4A ' : 'isom';
  return join(
    ftyp(brand, brand),
    box('moov', box('trak', box('mdia', hdlr(handler)))),
    box('mdat', Uint8Array.of(1))
  );
}

/** Serve ranged GETs of `media` from a stub S3 client, as production storage would. */
function rangedStorage(media: Uint8Array, ranges: string[] = []) {
  return {
    send: async (command: GetObjectCommand) => {
      const range = command.input.Range!;
      ranges.push(range);
      const match = /^bytes=(\d+)-(\d+)$/.exec(range)!;
      return { Body: media.slice(Number(match[1]), Number(match[2]) + 1) };
    },
  };
}

/** Run the production probe; true when admitted, false when rejected as unsupported media. */
async function isAdmitted(media: Uint8Array, type: 'audio' | 'video'): Promise<boolean> {
  try {
    await assertSupportedMediaContainer(
      rangedStorage(media) as never,
      'fixture',
      type,
      media.length
    );
    return true;
  } catch (error) {
    if (error instanceof ApiError && error.code === 'UPLOAD_INVALID') return false;
    throw error;
  }
}

describe('structural ISO-BMFF media admission', () => {
  it('accepts minimal bounded audio and video fixtures', async () => {
    expect(await isAdmitted(fixture('audio'), 'audio')).toBe(true);
    expect(await isAdmitted(fixture('video'), 'video')).toBe(true);
  });

  it('rejects marker-only payloads and wrong handlers without scanning arbitrary bytes', async () => {
    const markerOnly = Buffer.from('\0\0\0\x18ftypM4A \0\0\0\0M4A soun');
    const wrongAudio = join(
      ftyp('M4A ', 'M4A '),
      box('moov', box('trak', box('mdia', hdlr('vide')))),
      box('mdat', Uint8Array.of(1))
    );
    expect(await isAdmitted(markerOnly, 'audio')).toBe(false);
    expect(await isAdmitted(wrongAudio, 'audio')).toBe(false);
  });

  it.each([
    ['truncated', Uint8Array.of(0, 0, 0, 16, ...Buffer.from('ftyp'))],
    ['declared size exceeds input', join(Uint8Array.of(0, 0, 1, 0), Buffer.from('ftyp'))],
    [
      'missing mdat',
      join(ftyp('M4A ', 'M4A '), box('moov', box('trak', box('mdia', hdlr('soun'))))),
    ],
    [
      'wrong hierarchy',
      join(ftyp('M4A ', 'M4A '), box('moov', hdlr('soun')), box('mdat', Uint8Array.of(1))),
    ],
    [
      'zero size before EOF',
      join(Uint8Array.of(0, 0, 0, 0), Buffer.from('free'), box('mdat', Uint8Array.of(1))),
    ],
    [
      'overflowing extended size',
      join(
        Uint8Array.of(0, 0, 0, 1),
        Buffer.from('ftyp'),
        new Uint8Array([255, 255, 255, 255, 255, 255, 255, 255])
      ),
    ],
    [
      'duplicate ftyp',
      join(
        ftyp('M4A ', 'M4A '),
        ftyp('M4A ', 'M4A '),
        box('moov', box('trak', box('mdia', hdlr('soun')))),
        box('mdat', Uint8Array.of(1))
      ),
    ],
  ])('rejects %s', async (_name, value) => {
    expect(await isAdmitted(value, 'audio')).toBe(false);
  });

  it('accepts a deliberate 64-bit extended mdat size when structurally bounded', async () => {
    const media = join(
      ftyp('M4A ', 'M4A '),
      box('moov', box('trak', box('mdia', hdlr('soun')))),
      box('mdat', Uint8Array.of(1), true)
    );
    expect(await isAdmitted(media, 'audio')).toBe(true);
  });

  it('reduces the 66-request top-level probe baseline to one cached range request', async () => {
    const media = join(
      ...Array.from({ length: 61 }, () => box('free')),
      ftyp('M4A ', 'M4A '),
      box('moov', box('trak', box('mdia', hdlr('soun')))),
      box('mdat', Uint8Array.of(1))
    );
    const ranges: string[] = [];
    const s3 = rangedStorage(media, ranges);

    await expect(
      assertSupportedMediaContainer(s3 as never, 'fixture', 'audio', media.length)
    ).resolves.toBeUndefined();
    expect(ranges).toEqual([`bytes=0-${media.length - 1}`]);
  });

  it('includes slow response-body consumption in the probe deadline and aborts storage', async () => {
    let signal: AbortSignal | undefined;
    const s3 = {
      send: async (_command: GetObjectCommand, options: { abortSignal: AbortSignal }) => {
        signal = options.abortSignal;
        return {
          Body: { transformToByteArray: () => new Promise<Uint8Array>(() => undefined) },
        };
      },
    };

    await expect(
      assertSupportedMediaContainer(s3 as never, 'slow-fixture', 'audio', 128, { timeoutMs: 20 })
    ).rejects.toThrow('S3 media probe timed out after 20ms');
    expect(signal?.aborted).toBe(true);
  });
});
