import 'dart:convert';
import 'dart:typed_data';

/// Pure-Dart parser for Microsoft Excel BIFF8 (.xls) binary workbooks wrapped in OLE2 containers.
class Biff8Parser {
  /// Checks if file bytes match the OLE2 compound document header
  static bool isOle2(List<int> bytes) {
    if (bytes.length < 8) return false;
    const oleMagic = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
    for (int i = 0; i < 8; i++) {
      if (bytes[i] != oleMagic[i]) return false;
    }
    return true;
  }

  /// Parses an OLE2 BIFF8 .xls file and returns 2D table rows: List<List<dynamic>>
  static List<List<dynamic>> parseRows(List<int> bytes) {
    try {
      if (!isOle2(bytes)) return [];
      final u8 = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
      final byteData = ByteData.sublistView(u8);

      final sectorShift = byteData.getUint16(30, Endian.little);
      final sectorSize = 1 << sectorShift;
      final numFatSectors = byteData.getUint32(44, Endian.little);
      final firstDirSector = byteData.getUint32(48, Endian.little);

      // Read FAT sector IDs from header MSAT (up to 109 entries)
      final fatSectors = <int>[];
      for (int i = 0; i < numFatSectors && i < 109; i++) {
        fatSectors.add(byteData.getUint32(76 + i * 4, Endian.little));
      }

      // Assemble FAT
      final fat = <int>[];
      for (final s in fatSectors) {
        final start = (s + 1) * sectorSize;
        if (start + sectorSize <= u8.length) {
          final sView = ByteData.sublistView(u8, start, start + sectorSize);
          for (int off = 0; off < sectorSize; off += 4) {
            fat.add(sView.getUint32(off, Endian.little));
          }
        }
      }

      List<int> getChain(int startSec) {
        final chain = <int>[];
        int curr = startSec;
        while (curr != 0xFFFFFFFE && curr < fat.length && chain.length < 10000) {
          chain.add(curr);
          curr = fat[curr];
        }
        return chain;
      }

      // Assemble Directory stream
      final dirChain = getChain(firstDirSector);
      final dirBytesBuilder = BytesBuilder(copy: false);
      for (final s in dirChain) {
        final start = (s + 1) * sectorSize;
        if (start + sectorSize <= u8.length) {
          dirBytesBuilder.add(u8.sublist(start, start + sectorSize));
        }
      }
      final dirBytes = dirBytesBuilder.takeBytes();
      final dirData = ByteData.sublistView(dirBytes);

      // Find "Workbook" or "Book" directory entry (each entry is 128 bytes)
      int workbookStartSec = -1;
      int workbookSize = 0;
      for (int off = 0; off + 128 <= dirBytes.length; off += 128) {
        final nameLen = dirData.getUint16(off + 64, Endian.little);
        if (nameLen > 2 && nameLen <= 64) {
          final nameRaw = dirBytes.sublist(off, off + nameLen);
          final name = _decodeUtf16Le(nameRaw).replaceAll('\x00', '');
          if (name.contains("Workbook") || name.contains("Book")) {
            workbookStartSec = dirData.getUint32(off + 116, Endian.little);
            workbookSize = dirData.getUint32(off + 120, Endian.little);
            break;
          }
        }
      }

      if (workbookStartSec == -1 || workbookSize <= 0) {
        return [];
      }

      // Assemble Workbook stream
      final wbChain = getChain(workbookStartSec);
      final wbBuilder = BytesBuilder(copy: false);
      for (final s in wbChain) {
        final start = (s + 1) * sectorSize;
        if (start + sectorSize <= u8.length) {
          wbBuilder.add(u8.sublist(start, start + sectorSize));
        }
      }
      final fullWbBytes = wbBuilder.takeBytes();
      final wbBytes = fullWbBytes.length > workbookSize
          ? fullWbBytes.sublist(0, workbookSize)
          : fullWbBytes;

      return _parseBiff8Workbook(wbBytes);
    } catch (e) {
      return [];
    }
  }

  static List<List<dynamic>> _parseBiff8Workbook(Uint8List wb) {
    final byteData = ByteData.sublistView(wb);
    final records = <_BiffRecord>[];
    int pos = 0;
    while (pos + 4 <= wb.length) {
      final recType = byteData.getUint16(pos, Endian.little);
      final recLen = byteData.getUint16(pos + 2, Endian.little);
      pos += 4;
      if (pos + recLen > wb.length) break;
      records.add(_BiffRecord(recType, wb.sublist(pos, pos + recLen)));
      pos += recLen;
    }

    // Collect SST (0x00FC) and CONTINUE (0x003C) records
    final sstChunks = <Uint8List>[];
    for (int i = 0; i < records.length; i++) {
      if (records[i].type == 0x00FC) {
        sstChunks.add(records[i].data);
        int j = i + 1;
        while (j < records.length && records[j].type == 0x003C) {
          sstChunks.add(records[j].data);
          j++;
        }
        break;
      }
    }

    final sstStrings = _decodeSst(sstChunks);

    // Extract cell values
    final Map<int, Map<int, dynamic>> cells = {};
    for (final rec in records) {
      final rData = rec.data;
      if (rec.type == 0x00FD && rData.length >= 10) {
        // LABELSST: row, col, xf, sstIndex
        final bd = ByteData.sublistView(rData);
        final row = bd.getUint16(0, Endian.little);
        final col = bd.getUint16(2, Endian.little);
        final sstIdx = bd.getUint32(6, Endian.little);
        final val = sstIdx < sstStrings.length ? sstStrings[sstIdx] : "";
        cells.putIfAbsent(row, () => {})[col] = val;
      } else if (rec.type == 0x0203 && rData.length >= 14) {
        // NUMBER: row, col, xf, double
        final bd = ByteData.sublistView(rData);
        final row = bd.getUint16(0, Endian.little);
        final col = bd.getUint16(2, Endian.little);
        final numVal = bd.getFloat64(6, Endian.little);
        cells.putIfAbsent(row, () => {})[col] =
            numVal.truncateToDouble() == numVal
                ? numVal.toInt().toString()
                : numVal.toStringAsFixed(2);
      } else if (rec.type == 0x027E && rData.length >= 10) {
        // RK: row, col, xf, rkValue
        final bd = ByteData.sublistView(rData);
        final row = bd.getUint16(0, Endian.little);
        final col = bd.getUint16(2, Endian.little);
        final rk = bd.getUint32(6, Endian.little);
        final numVal = _decodeRk(rk);
        cells.putIfAbsent(row, () => {})[col] = numVal != null
            ? (numVal.truncateToDouble() == numVal
                ? numVal.toInt().toString()
                : numVal.toStringAsFixed(2))
            : "";
      } else if (rec.type == 0x00BD && rData.length >= 6) {
        // MULRK: row, firstCol, (xf, rk)*, lastCol
        final bd = ByteData.sublistView(rData);
        final row = bd.getUint16(0, Endian.little);
        final firstCol = bd.getUint16(2, Endian.little);
        final lastCol = bd.getUint16(rData.length - 2, Endian.little);
        int rkOff = 4;
        for (int c = firstCol; c <= lastCol && rkOff + 6 <= rData.length; c++) {
          final rk = bd.getUint32(rkOff + 2, Endian.little);
          final numVal = _decodeRk(rk);
          if (numVal != null) {
            cells.putIfAbsent(row, () => {})[c] =
                numVal.truncateToDouble() == numVal
                    ? numVal.toInt().toString()
                    : numVal.toStringAsFixed(2);
          }
          rkOff += 6;
        }
      } else if (rec.type == 0x0204 && rData.length >= 8) {
        // LABEL: row, col, xf, string
        final bd = ByteData.sublistView(rData);
        final row = bd.getUint16(0, Endian.little);
        final col = bd.getUint16(2, Endian.little);
        final len = bd.getUint16(6, Endian.little);
        if (rData.length >= 8 + len) {
          cells.putIfAbsent(row, () => {})[col] =
              latin1.decode(rData.sublist(8, 8 + len));
        }
      }
    }

    if (cells.isEmpty) return [];

    int maxRow = 0;
    int maxCol = 0;
    for (final r in cells.keys) {
      if (r > maxRow) maxRow = r;
      for (final c in cells[r]!.keys) {
        if (c > maxCol) maxCol = c;
      }
    }

    final List<List<dynamic>> result = [];
    for (int r = 0; r <= maxRow; r++) {
      final rowMap = cells[r];
      if (rowMap == null || rowMap.isEmpty) {
        result.add(List.filled(maxCol + 1, ""));
      } else {
        final rowList = <dynamic>[];
        for (int c = 0; c <= maxCol; c++) {
          rowList.add(rowMap[c]?.toString() ?? "");
        }
        result.add(rowList);
      }
    }
    return result;
  }

  static double? _decodeRk(int rk) {
    double val;
    if ((rk & 0x02) != 0) {
      // 30-bit signed integer
      int intVal = (rk >> 2);
      if ((intVal & 0x20000000) != 0) {
        intVal -= 0x40000000;
      }
      val = intVal.toDouble();
    } else {
      // IEEE float with 34 lower zero bits
      final u64 = (BigInt.from(rk & 0xFFFFFFFC) << 32).toUnsigned(64);
      final b = ByteData(8);
      b.setUint64(0, u64.toInt(), Endian.little);
      val = b.getFloat64(0, Endian.little);
    }
    if ((rk & 0x01) != 0) {
      val /= 100.0;
    }
    return val;
  }

  static List<String> _decodeSst(List<Uint8List> chunks) {
    if (chunks.isEmpty) return [];
    final reader = _SstReader(chunks);
    final headerBytes = reader.readBytes(8);
    if (headerBytes.length < 8) return [];
    final hBd = ByteData.sublistView(headerBytes);
    final uniqueCount = hBd.getUint32(4, Endian.little);

    final strings = <String>[];
    for (int i = 0; i < uniqueCount; i++) {
      final hdr = reader.readBytes(3);
      if (hdr.length < 3) break;
      final charCount = hdr[0] | (hdr[1] << 8);
      final flags = hdr[2];
      final is16Bit = (flags & 0x01) != 0;
      final hasRich = (flags & 0x08) != 0;
      final hasExt = (flags & 0x04) != 0;

      int richCount = 0;
      int extSize = 0;
      if (hasRich) {
        final rb = reader.readBytes(2);
        if (rb.length == 2) {
          richCount = rb[0] | (rb[1] << 8);
        }
      }
      if (hasExt) {
        final eb = reader.readBytes(4);
        if (eb.length == 4) {
          extSize = eb[0] | (eb[1] << 8) | (eb[2] << 16) | (eb[3] << 24);
        }
      }

      final s = reader.readStringChars(charCount, is16Bit);
      strings.add(s);

      if (richCount > 0) reader.readBytes(richCount * 4);
      if (extSize > 0) reader.readBytes(extSize);
    }
    return strings;
  }

  static String _decodeUtf16Le(Uint8List bytes) {
    final chars = <int>[];
    for (int i = 0; i + 1 < bytes.length; i += 2) {
      chars.add(bytes[i] | (bytes[i + 1] << 8));
    }
    return String.fromCharCodes(chars);
  }
}

class _BiffRecord {
  final int type;
  final Uint8List data;
  _BiffRecord(this.type, this.data);
}

class _SstReader {
  final List<Uint8List> chunks;
  int ci = 0;
  int cpos = 0;

  _SstReader(this.chunks);

  Uint8List readBytes(int n) {
    final builder = BytesBuilder(copy: false);
    int remaining = n;
    while (remaining > 0 && ci < chunks.length) {
      final avail = chunks[ci].length - cpos;
      if (avail <= 0) {
        ci++;
        cpos = 0;
        continue;
      }
      final take = remaining < avail ? remaining : avail;
      builder.add(chunks[ci].sublist(cpos, cpos + take));
      cpos += take;
      remaining -= take;
      if (cpos >= chunks[ci].length) {
        ci++;
        cpos = 0;
      }
    }
    return builder.takeBytes();
  }

  String readStringChars(int charCount, bool initial16Bit) {
    final chars = <int>[];
    int charsLeft = charCount;
    bool curr16Bit = initial16Bit;

    while (charsLeft > 0 && ci < chunks.length) {
      final bytesPerChar = curr16Bit ? 2 : 1;
      final availBytes = chunks[ci].length - cpos;
      final availChars = availBytes ~/ bytesPerChar;

      if (availChars <= 0) {
        ci++;
        cpos = 0;
        if (ci < chunks.length && charsLeft > 0) {
          final flag = chunks[ci][0];
          cpos = 1;
          curr16Bit = (flag & 0x01) != 0;
        }
        continue;
      }

      final takeChars = charsLeft < availChars ? charsLeft : availChars;
      final takeBytes = takeChars * bytesPerChar;
      final chunkSlice = chunks[ci];

      if (curr16Bit) {
        for (int i = 0; i < takeBytes; i += 2) {
          chars.add(chunkSlice[cpos + i] | (chunkSlice[cpos + i + 1] << 8));
        }
      } else {
        for (int i = 0; i < takeBytes; i++) {
          chars.add(chunkSlice[cpos + i]);
        }
      }

      cpos += takeBytes;
      charsLeft -= takeChars;

      if (cpos >= chunks[ci].length) {
        ci++;
        cpos = 0;
        if (ci < chunks.length && charsLeft > 0) {
          final flag = chunks[ci][0];
          cpos = 1;
          curr16Bit = (flag & 0x01) != 0;
        }
      }
    }
    return String.fromCharCodes(chars);
  }
}
