import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:budget/struct/statementImporter/statementParser.dart';
import 'package:budget/struct/smsReview/reviewManager.dart';
import 'package:budget/database/platform/native.dart';

void main() {
  group('StatementParser.parseAmount', () {
    test('parses plain decimal amounts', () {
      expect(StatementParser.parseAmount("123.45"), equals(123.45));
      expect(StatementParser.parseAmount("0.00"), equals(0.0));
      expect(StatementParser.parseAmount("9999"), equals(9999.0));
    });

    test('cleans currency symbols and thousands commas', () {
      expect(StatementParser.parseAmount("₹ 1,234.50"), equals(1234.50));
      expect(StatementParser.parseAmount("\$1,000,000.99"), equals(1000000.99));
      expect(StatementParser.parseAmount("CR 5,432.10"), equals(5432.10));
    });

    test('handles negative values, trailing minus, and accounting parentheses', () {
      expect(StatementParser.parseAmount("-500.25"), equals(-500.25));
      expect(StatementParser.parseAmount("500.25-"), equals(-500.25));
      expect(StatementParser.parseAmount("(1,234.50)"), equals(-1234.50));
    });

    test('returns 0.0 for empty or invalid strings', () {
      expect(StatementParser.parseAmount(""), equals(0.0));
      expect(StatementParser.parseAmount("   "), equals(0.0));
      expect(StatementParser.parseAmount("abc"), equals(0.0));
    });
  });

  group('StatementParser.parseFlexibleDate', () {
    test('parses DD-MM-YYYY, DD/MM/YYYY, and DD.MM.YYYY', () {
      expect(
        StatementParser.parseFlexibleDate("04-11-2026"),
        equals(DateTime(2026, 11, 4)),
      );
      expect(
        StatementParser.parseFlexibleDate("15/08/2025"),
        equals(DateTime(2025, 8, 15)),
      );
      expect(
        StatementParser.parseFlexibleDate("31.12.2024"),
        equals(DateTime(2024, 12, 31)),
      );
    });

    test('expands 2-digit years to 2000s', () {
      expect(
        StatementParser.parseFlexibleDate("04-11-26"),
        equals(DateTime(2026, 11, 4)),
      );
      expect(
        StatementParser.parseFlexibleDate("10/05/25"),
        equals(DateTime(2025, 5, 10)),
      );
    });

    test('ignores trailing time information in datetime strings', () {
      expect(
        StatementParser.parseFlexibleDate("04/11/2026 14:30:00"),
        equals(DateTime(2026, 11, 4)),
      );
      expect(
        StatementParser.parseFlexibleDate("04-11-2026 09:15:22 AM"),
        equals(DateTime(2026, 11, 4)),
      );
    });

    test('parses alphabetic month formats (DD-MMM-YYYY)', () {
      expect(
        StatementParser.parseFlexibleDate("04-Nov-2026"),
        equals(DateTime(2026, 11, 4)),
      );
      expect(
        StatementParser.parseFlexibleDate("04-Nov-26"),
        equals(DateTime(2026, 11, 4)),
      );
      expect(
        StatementParser.parseFlexibleDate("04 Nov 2026"),
        equals(DateTime(2026, 11, 4)),
      );
    });

    test('returns null for blank or unparseable input', () {
      expect(StatementParser.parseFlexibleDate(""), isNull);
      expect(StatementParser.parseFlexibleDate("    "), isNull);
      expect(StatementParser.parseFlexibleDate("not-a-date"), isNull);
    });
  });

  group('ReviewManager.extractBankBrand - Word Boundaries & False Positives', () {
    test('accurately extracts bank brands when present as whole tokens', () {
      expect(ReviewManager.extractBankBrand("Yes Bank credit card bill"), equals("yes"));
      expect(ReviewManager.extractBankBrand("HDFC Bank statement alert"), equals("hdfc"));
      expect(ReviewManager.extractBankBrand("ICICI Bank NetBanking"), equals("icici"));
      expect(ReviewManager.extractBankBrand("SBI Card ending in 1234"), equals("sbi"));
      expect(ReviewManager.extractBankBrand("State Bank of India"), equals("sbi"));
      expect(ReviewManager.extractBankBrand("BOB credit card statement"), equals("bob"));
      expect(ReviewManager.extractBankBrand("Bank of Baroda debit"), equals("bob"));
      expect(ReviewManager.extractBankBrand("Kotak Mahindra Bank"), equals("kotak"));
      expect(ReviewManager.extractBankBrand("Axis Bank transaction"), equals("axis"));
    });

    test('prevents false-positive word collisions with common words', () {
      // 'yes' should NOT match 'yesterday'
      expect(ReviewManager.extractBankBrand("yesterday dinner with friends"), isNull);

      // 'bob' should NOT match 'kebabs'
      expect(ReviewManager.extractBankBrand("kebabs and rolls for party"), isNull);

      // 'rbl' should NOT match random strings
      expect(ReviewManager.extractBankBrand("garbled text message"), isNull);

      // general non-banking text
      expect(ReviewManager.extractBankBrand("paid 500 at grocery store"), isNull);
    });
  });

  group('isValidSqliteHeader', () {
    test('returns true for exact 16-byte SQLite header', () {
      final validHeader = Uint8List.fromList([
        0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66,
        0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00,
        0x01, 0x02, 0x03, 0x04,
      ]);
      expect(isValidSqliteHeader(validHeader), isTrue);
    });

    test('returns false for headers shorter than 16 bytes or corrupt bytes', () {
      expect(isValidSqliteHeader(Uint8List.fromList([1, 2, 3])), isFalse);

      final corrupted = Uint8List.fromList([
        0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66,
        0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x32, 0x00, // '2' instead of '3'
      ]);
      expect(isValidSqliteHeader(corrupted), isFalse);
    });
  });
}
