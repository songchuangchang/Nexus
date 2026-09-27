/// v1.7.50（build106）：WGS-84 → GCJ-02（火星坐标）纯函数转换。
///
/// 背景：设备 GPS 返回 WGS-84 坐标，而高德全系列接口（MCP maps_* 工具、
/// restapi.amap.com）只认 GCJ-02。不转换直接喂给高德会偏移约 100~700 米，
/// 「最近地铁站」会答错站。本文件实现业界公开的标准偏移公式（无网络依赖，
/// 纯 dart:convert 级实现，可被 `dart run` 探针直接验证）。
library;

import 'dart:math' as math;

/// 克拉索夫斯基椭球长半轴与第一偏心率平方（GCJ-02 公开算法常量）
const double _kEllipseA = 6378245.0;
const double _kEllipseEE = 0.00669342162296594323;

/// 是否在中国大陆坐标范围外（境外无偏移，原样返回）
bool outOfChina(double lat, double lng) =>
    lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271;

double _transformLat(double x, double y) {
  var ret = -100.0 +
      2.0 * x +
      3.0 * y +
      0.2 * y * y +
      0.1 * x * y +
      0.2 * math.sqrt(x.abs());
  ret += (20.0 * math.sin(6.0 * x * math.pi) +
          20.0 * math.sin(2.0 * x * math.pi)) *
      2.0 /
      3.0;
  ret += (20.0 * math.sin(y * math.pi) +
          40.0 * math.sin(y / 3.0 * math.pi)) *
      2.0 /
      3.0;
  ret += (160.0 * math.sin(y / 12.0 * math.pi) +
          320.0 * math.sin(y * math.pi / 30.0)) *
      2.0 /
      3.0;
  return ret;
}

double _transformLng(double x, double y) {
  var ret = 300.0 +
      x +
      2.0 * y +
      0.1 * x * x +
      0.1 * x * y +
      0.1 * math.sqrt(x.abs());
  ret += (20.0 * math.sin(6.0 * x * math.pi) +
          20.0 * math.sin(2.0 * x * math.pi)) *
      2.0 /
      3.0;
  ret += (20.0 * math.sin(x * math.pi) +
          40.0 * math.sin(x / 3.0 * math.pi)) *
      2.0 /
      3.0;
  ret += (150.0 * math.sin(x / 12.0 * math.pi) +
          300.0 * math.sin(x / 30.0 * math.pi)) *
      2.0 /
      3.0;
  return ret;
}

/// WGS-84 → GCJ-02。返回 `[lat, lng]`；中国境外原样返回。
List<double> wgs84ToGcj02(double lat, double lng) {
  if (outOfChina(lat, lng)) return [lat, lng];
  var dLat = _transformLat(lng - 105.0, lat - 35.0);
  var dLng = _transformLng(lng - 105.0, lat - 35.0);
  final radLat = lat / 180.0 * math.pi;
  var magic = math.sin(radLat);
  magic = 1 - _kEllipseEE * magic * magic;
  final sqrtMagic = math.sqrt(magic);
  dLat = (dLat * 180.0) /
      ((_kEllipseA * (1 - _kEllipseEE)) / (magic * sqrtMagic) * math.pi);
  dLng = (dLng * 180.0) /
      (_kEllipseA / sqrtMagic * math.cos(radLat) * math.pi);
  return [lat + dLat, lng + dLng];
}
