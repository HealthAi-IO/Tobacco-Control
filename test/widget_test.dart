import 'package:flutter_test/flutter_test.dart';

import 'package:tobacco_control/main.dart';

void main() {
  test('smoking periods follow the daily control rules', () {
    expect(currentPeriod(DateTime(2026, 5, 15, 10, 59)), SmokePeriod.closed);
    expect(currentPeriod(DateTime(2026, 5, 15, 11, 0)), SmokePeriod.morning);
    expect(currentPeriod(DateTime(2026, 5, 15, 12, 0)), SmokePeriod.afternoon);
    expect(currentPeriod(DateTime(2026, 5, 15, 18, 0)), SmokePeriod.evening);
    expect(currentPeriod(DateTime(2026, 5, 15, 23, 0)), SmokePeriod.closed);
  });

  test('daily slots keep afternoon and evening evenly distributed', () {
    final slots = slotsForDay(DateTime(2026, 5, 15));

    expect(slots.length, 7);
    expect(slots[0].time, DateTime(2026, 5, 15, 11));
    expect(slots[1].time, DateTime(2026, 5, 15, 12));
    expect(slots[2].time, DateTime(2026, 5, 15, 15));
    expect(slots[3].time, DateTime(2026, 5, 15, 17, 30));
    expect(slots[4].time, DateTime(2026, 5, 15, 18));
    expect(slots[5].time, DateTime(2026, 5, 15, 20, 30));
    expect(slots[6].time, DateTime(2026, 5, 15, 22, 30));
  });

  test('Chinese date formatter does not require locale initialization', () {
    expect(formatChineseDate(DateTime(2026, 5, 15)), '5月15日 星期五');
  });
}
