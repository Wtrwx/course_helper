import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as im;
import 'package:pdf/pdf.dart';

class SlideImageException implements Exception {
  const SlideImageException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Writes image-only slide pages directly to disk. Only one encoded image is
/// held at a time; the document retains object offsets, not image buffers.
class SlidePdfWriter {
  SlidePdfWriter._(this._file, this.pageWidth, this.pageHeight);

  static const int maxImageBytes = 64 * 1024 * 1024;
  static const int maxRasterPixels = 16 * 1024 * 1024;

  final RandomAccessFile _file;
  final double pageWidth;
  final double pageHeight;
  final List<int> _offsets = [0, 0, 0]; // Free object, catalog, page tree.
  final List<int> _pages = [];
  int _position = 0;
  bool _closed = false;

  int get pageCount => _pages.length;

  static Future<SlidePdfWriter> open(
    File output, {
    required double pageWidth,
    required double pageHeight,
  }) async {
    if (!pageWidth.isFinite ||
        !pageHeight.isFinite ||
        pageWidth <= 0 ||
        pageHeight <= 0) {
      throw ArgumentError('Invalid PDF page dimensions');
    }
    final file = await output.open(mode: FileMode.write);
    final writer = SlidePdfWriter._(file, pageWidth, pageHeight);
    try {
      await writer._writeBytes(
        latin1.encode('%PDF-1.4\n%\u00e2\u00e3\u00cf\u00d3\n'),
      );
      await writer._writeObject(1, '<< /Type /Catalog /Pages 2 0 R >>');
      return writer;
    } catch (_) {
      await writer.close();
      rethrow;
    }
  }

  Future<void> addImageFile(File source) async {
    if (_closed) throw StateError('The PDF is already closed');
    // Pass a path into the isolate, never a document or a full batch of bytes.
    final image = await _encodeInBackground(source.path);
    final pageId = _reserveObject();
    final contentId = _reserveObject();
    final imageId = _reserveObject();
    final alphaId = image.alpha == null ? null : _reserveObject();

    await _writeStream(
      imageId,
      '/Type /XObject /Subtype /Image '
      '/Width ${image.width} /Height ${image.height} '
      '/BitsPerComponent 8 /ColorSpace /${image.colorSpace} '
      '/Filter /${image.filter} '
      '${image.invertedCmyk ? '/Decode [1 0 1 0 1 0 1 0] ' : ''}'
      '${alphaId == null ? '' : '/SMask $alphaId 0 R '}',
      image.data,
    );
    if (alphaId != null) {
      await _writeStream(
        alphaId,
        '/Type /XObject /Subtype /Image '
        '/Width ${image.width} /Height ${image.height} '
        '/BitsPerComponent 8 /ColorSpace /DeviceGray /Filter /FlateDecode',
        image.alpha!,
      );
    }

    final rotated = image.orientation.index >= 4;
    final width = rotated ? image.height : image.width;
    final height = rotated ? image.width : image.height;
    final scale = math.min(pageWidth / width, pageHeight / height);
    final drawWidth = width * scale;
    final drawHeight = height * scale;
    // Match the existing slide export's top-left page placement when the
    // source image and the presentation have different aspect ratios.
    const x = 0.0;
    final y = pageHeight - drawHeight;
    final matrix = _imageMatrix(image.orientation, drawWidth, drawHeight, x, y);
    await _writeStream(
      contentId,
      '',
      ascii.encode('q ${matrix.map(_number).join(' ')} cm /Im0 Do Q\n'),
    );
    await _writeObject(
      pageId,
      '<< /Type /Page /Parent 2 0 R '
      '/MediaBox [0 0 ${_number(pageWidth)} ${_number(pageHeight)}] '
      '/Resources << /XObject << /Im0 $imageId 0 R >> >> '
      '/Contents $contentId 0 R >>',
    );
    _pages.add(pageId);
  }

  Future<void> finish() async {
    if (_closed) throw StateError('The PDF is already closed');
    try {
      if (_pages.isEmpty) throw StateError('Cannot save an empty PDF');
      await _writeObject(
        2,
        '<< /Type /Pages /Count ${_pages.length} '
        '/Kids [${_pages.map((id) => '$id 0 R').join(' ')}] >>',
      );
      final xrefOffset = _position;
      final xref = StringBuffer(
        'xref\n0 ${_offsets.length}\n0000000000 65535 f \n',
      );
      for (final offset in _offsets.skip(1)) {
        xref.writeln('${offset.toString().padLeft(10, '0')} 00000 n ');
      }
      xref.write(
        'trailer\n<< /Size ${_offsets.length} /Root 1 0 R >>\n'
        'startxref\n$xrefOffset\n%%EOF\n',
      );
      await _writeAscii(xref.toString());
      await _file.flush();
    } finally {
      await close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _file.close();
  }

  int _reserveObject() {
    final id = _offsets.length;
    _offsets.add(0);
    return id;
  }

  Future<void> _writeObject(int id, String body) async {
    _offsets[id] = _position;
    await _writeAscii('$id 0 obj\n$body\nendobj\n');
  }

  Future<void> _writeStream(int id, String dictionary, List<int> bytes) async {
    _offsets[id] = _position;
    await _writeAscii(
      '$id 0 obj\n<< $dictionary /Length ${bytes.length} >>\nstream\n',
    );
    await _writeBytes(bytes);
    await _writeAscii('\nendstream\nendobj\n');
  }

  Future<void> _writeAscii(String text) => _writeBytes(ascii.encode(text));

  Future<void> _writeBytes(List<int> bytes) async {
    await _file.writeFrom(bytes);
    _position += bytes.length;
  }

  static String _number(double value) => value.toStringAsFixed(5);

  static List<double> _imageMatrix(
    PdfImageOrientation orientation,
    double w,
    double h,
    double x,
    double y,
  ) => switch (orientation) {
    PdfImageOrientation.topLeft => [w, 0, 0, h, x, y],
    PdfImageOrientation.topRight => [-w, 0, 0, h, w + x, y],
    PdfImageOrientation.bottomRight => [-w, 0, 0, -h, w + x, h + y],
    PdfImageOrientation.bottomLeft => [w, 0, 0, -h, x, h + y],
    PdfImageOrientation.leftTop => [0, -h, -w, 0, w + x, h + y],
    PdfImageOrientation.rightTop => [0, -h, w, 0, x, h + y],
    PdfImageOrientation.rightBottom => [0, h, w, 0, x, y],
    PdfImageOrientation.leftBottom => [0, h, -w, 0, w + x, y],
  };
}

class _EncodedImage {
  const _EncodedImage({
    required this.width,
    required this.height,
    required this.data,
    this.colorSpace = 'DeviceRGB',
    this.filter = 'FlateDecode',
    this.orientation = PdfImageOrientation.topLeft,
    this.invertedCmyk = false,
    this.alpha,
  });

  final int width;
  final int height;
  final Uint8List data;
  final String colorSpace;
  final String filter;
  final PdfImageOrientation orientation;
  final bool invertedCmyk;
  final Uint8List? alpha;
}

Future<_EncodedImage> _encodeInBackground(String path) =>
    Isolate.run(() => _encodeFile(path), debugName: 'slide_pdf_image');

_EncodedImage _encodeFile(String path) {
  final file = File(path);
  if (file.lengthSync() > SlidePdfWriter.maxImageBytes) {
    throw const SlideImageException('图片文件过大');
  }
  final bytes = file.readAsBytesSync();
  try {
    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      final info = PdfJpegInfo(bytes);
      final width = info.width ?? 0;
      if (width <= 0 || info.height <= 0) {
        throw const SlideImageException('图片尺寸无效');
      }
      return _EncodedImage(
        width: width,
        height: info.height,
        data: bytes,
        filter: 'DCTDecode',
        colorSpace: info.isCMYK
            ? 'DeviceCMYK'
            : (info.isRGB ? 'DeviceRGB' : 'DeviceGray'),
        orientation: info.orientation,
        invertedCmyk: info.isCMYKInverted,
      );
    }

    final decoder = im.findDecoderForData(bytes);
    final info = decoder?.startDecode(bytes);
    if (info == null || info.width <= 0 || info.height <= 0) {
      throw const SlideImageException('图片格式或尺寸无效');
    }
    // Reject oversized rasters before allocating the decoded pixel buffer.
    if (info.width * info.height > SlidePdfWriter.maxRasterPixels) {
      throw const SlideImageException('图片分辨率过大');
    }
    final decoded = decoder!.decodeFrame(0);
    if (decoded == null) throw const SlideImageException('图片解码失败');
    Uint8List? alpha;
    if (decoded.hasAlpha) {
      final channel = Uint8List(decoded.width * decoded.height);
      var index = 0;
      var opaque = true;
      for (final pixel in decoded) {
        final value = (pixel.aNormalized * 255).round().clamp(0, 255);
        channel[index++] = value;
        if (value != 255) opaque = false;
      }
      if (!opaque) alpha = Uint8List.fromList(zlib.encode(channel));
    }
    final rgb = decoded
        .convert(format: im.Format.uint8, numChannels: 3, noAnimation: true)
        .getBytes();
    return _EncodedImage(
      width: decoded.width,
      height: decoded.height,
      data: Uint8List.fromList(zlib.encode(rgb)),
      alpha: alpha,
    );
  } on SlideImageException {
    rethrow;
  } catch (_) {
    throw const SlideImageException('图片解码失败');
  }
}
