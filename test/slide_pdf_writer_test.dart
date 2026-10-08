import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;

import 'package:course_helper/utils/slide_pdf_writer.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('slide_pdf_test_');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  Future<File> imageFile(String name, List<int> bytes) =>
      File('${directory.path}/$name').writeAsBytes(bytes);

  Future<SlidePdfWriter> openWriter() => SlidePdfWriter.open(
    File('${directory.path}/output.pdf'),
    pageWidth: 160,
    pageHeight: 90,
  );

  test(
    'mixed JPEG and PNG pages have valid cross references and page order',
    () async {
      final image = im.Image(width: 16, height: 9);
      im.fill(image, color: im.ColorRgb8(30, 90, 150));
      final jpeg = im.encodeJpg(image);
      final writer = await openWriter();
      await writer.addImageFile(await imageFile('first.jpg', jpeg));
      await writer.addImageFile(
        await imageFile('second.png', im.encodePng(image)),
      );
      expect(writer.pageCount, 2);
      await writer.finish();

      final bytes = await File('${directory.path}/output.pdf').readAsBytes();
      final text = latin1.decode(bytes);
      expect(text, contains('/Count 2 /Kids [3 0 R 6 0 R]'));
      expect(text, contains('/MediaBox [0 0 160.00000 90.00000]'));
      _verifyXref(bytes);
      final streams = _streams(bytes);
      expect(streams.first.data, orderedEquals(jpeg));
      expect(streams.first.dictionary, contains('/DCTDecode'));
      expect(zlib.decode(streams[2].data), orderedEquals(image.getBytes()));
    },
  );

  test(
    'transparent PNG preserves RGB and alpha without lossy conversion',
    () async {
      final image = im.Image(width: 2, height: 1, numChannels: 4);
      image.setPixelRgba(0, 0, 255, 0, 0, 128);
      image.setPixelRgba(1, 0, 0, 0, 255, 0);
      final writer = await openWriter();
      await writer.addImageFile(
        await imageFile('alpha.png', im.encodePng(image)),
      );
      await writer.finish();

      final bytes = await File('${directory.path}/output.pdf').readAsBytes();
      final streams = _streams(bytes);
      expect(streams.first.dictionary, contains('/SMask 6 0 R'));
      expect(zlib.decode(streams.first.data), [255, 0, 0, 0, 0, 255]);
      expect(zlib.decode(streams[1].data), [128, 0]);
      expect(
        ascii.decode(streams[2].data),
        'q 160.00000 0.00000 0.00000 80.00000 0.00000 10.00000 cm /Im0 Do Q\n',
      );
      _verifyXref(bytes);
    },
  );

  test('invalid image does not prevent subsequent valid pages', () async {
    final writer = await openWriter();
    final invalid = await imageFile('broken.png', utf8.encode('not an image'));
    await expectLater(
      writer.addImageFile(invalid),
      throwsA(isA<SlideImageException>()),
    );
    expect(writer.pageCount, 0);
    final image = im.Image(width: 2, height: 1);
    await writer.addImageFile(
      await imageFile('valid.png', im.encodePng(image)),
    );
    await writer.finish();
    expect(writer.pageCount, 1);
    _verifyXref(await File('${directory.path}/output.pdf').readAsBytes());
    await expectLater(writer.addImageFile(invalid), throwsStateError);
  });

  test('oversized raster is rejected before pixel decoding', () async {
    final png = Uint8List.fromList(im.encodePng(im.Image(width: 1, height: 1)));
    final header = ByteData.sublistView(png);
    header.setUint32(16, 5000);
    header.setUint32(20, 5000);
    header.setUint32(29, _crc32(png.sublist(12, 29)));
    final writer = await openWriter();
    await expectLater(
      writer.addImageFile(await imageFile('huge.png', png)),
      throwsA(
        isA<SlideImageException>().having(
          (e) => e.message,
          'message',
          '图片分辨率过大',
        ),
      ),
    );
    await writer.close();
  });

  test(
    'oversized input file is rejected before reading its contents',
    () async {
      final oversized = File('${directory.path}/huge.jpg');
      final handle = await oversized.open(mode: FileMode.write);
      await handle.truncate(SlidePdfWriter.maxImageBytes + 1);
      await handle.close();
      final writer = await openWriter();
      await expectLater(
        writer.addImageFile(oversized),
        throwsA(isA<SlideImageException>()),
      );
      await writer.close();
    },
  );

  test('empty PDF closes its file and close is idempotent', () async {
    final writer = await openWriter();
    await expectLater(writer.finish(), throwsStateError);
    await writer.close();
    await expectLater(writer.finish(), throwsStateError);
    await expectLater(
      SlidePdfWriter.open(
        File('${directory.path}/bad.pdf'),
        pageWidth: double.nan,
        pageHeight: 90,
      ),
      throwsArgumentError,
    );
  });
}

List<({String dictionary, Uint8List data})> _streams(Uint8List bytes) {
  final text = latin1.decode(bytes);
  final pattern = RegExp(
    r'\d+ 0 obj\n<< ([^\r\n]*) /Length (\d+) >>\nstream\n',
  );
  return pattern
      .allMatches(text)
      .map(
        (match) => (
          dictionary: match.group(1)!,
          data: bytes.sublist(
            match.end,
            match.end + int.parse(match.group(2)!),
          ),
        ),
      )
      .toList();
}

void _verifyXref(Uint8List bytes) {
  final text = latin1.decode(bytes);
  final offset = int.parse(
    RegExp(r'startxref\n(\d+)\n%%EOF').firstMatch(text)!.group(1)!,
  );
  final lines = text.substring(offset).split('\n');
  expect(lines.first, 'xref');
  final size = int.parse(lines[1].split(' ')[1]);
  for (var id = 1; id < size; id++) {
    final objectOffset = int.parse(lines[id + 2].substring(0, 10));
    expect(text.substring(objectOffset), startsWith('$id 0 obj\n'));
  }
}

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb88320);
    }
  }
  return crc ^ 0xffffffff;
}
