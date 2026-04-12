// GENERATED CODE - DO NOT MODIFY BY HAND
// Manually written for Phase 1

part of 'stock.dart';

class StockAdapter extends TypeAdapter<Stock> {
  @override
  final int typeId = 0;

  @override
  Stock read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Stock(
      code: fields[0] as String,
      name: fields[1] as String,
      price: fields[2] as double,
      prevClose: fields[3] as double,
      change: fields[4] as double,
      changePct: fields[5] as double,
      lastUpdate: fields[6] as DateTime,
      reportIntervalSec: fields[7] as int,
      enabled: fields[8] as bool,
    );
  }

  @override
  void write(BinaryWriter writer, Stock obj) {
    writer
      ..writeByte(9)
      ..writeByte(0)
      ..write(obj.code)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.price)
      ..writeByte(3)
      ..write(obj.prevClose)
      ..writeByte(4)
      ..write(obj.change)
      ..writeByte(5)
      ..write(obj.changePct)
      ..writeByte(6)
      ..write(obj.lastUpdate)
      ..writeByte(7)
      ..write(obj.reportIntervalSec)
      ..writeByte(8)
      ..write(obj.enabled);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StockAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
