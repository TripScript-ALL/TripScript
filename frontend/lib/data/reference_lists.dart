class CountryOption {
  final String name;
  final String code;
  final String flag;
  final double utcOffsetHours;

  const CountryOption({
    required this.name,
    required this.code,
    required this.flag,
    required this.utcOffsetHours,
  });
}

const bankOptions = [
  '국민은행',
  '신한은행',
  '우리은행',
  '하나은행',
  '농협은행',
  '기업은행',
  '카카오뱅크',
  '토스뱅크',
  '케이뱅크',
  'SC제일은행',
  '씨티은행',
  '수협은행',
  '부산은행',
  '대구은행',
  '경남은행',
  '광주은행',
  '전북은행',
  '제주은행',
  '새마을금고',
  '신협',
  '우체국',
  '산업은행',
  '저축은행',
  '증권사',
  '기타',
];

const countryOptions = [
  CountryOption(name: '대한민국', code: 'KR', flag: '🇰🇷', utcOffsetHours: 9),
  CountryOption(name: '일본', code: 'JP', flag: '🇯🇵', utcOffsetHours: 9),
  CountryOption(name: '중국', code: 'CN', flag: '🇨🇳', utcOffsetHours: 8),
  CountryOption(name: '대만', code: 'TW', flag: '🇹🇼', utcOffsetHours: 8),
  CountryOption(name: '홍콩', code: 'HK', flag: '🇭🇰', utcOffsetHours: 8),
  CountryOption(name: '태국', code: 'TH', flag: '🇹🇭', utcOffsetHours: 7),
  CountryOption(name: '베트남', code: 'VN', flag: '🇻🇳', utcOffsetHours: 7),
  CountryOption(name: '싱가포르', code: 'SG', flag: '🇸🇬', utcOffsetHours: 8),
  CountryOption(name: '말레이시아', code: 'MY', flag: '🇲🇾', utcOffsetHours: 8),
  CountryOption(name: '필리핀', code: 'PH', flag: '🇵🇭', utcOffsetHours: 8),
  CountryOption(name: '인도네시아', code: 'ID', flag: '🇮🇩', utcOffsetHours: 7),
  CountryOption(name: '영국', code: 'GB', flag: '🇬🇧', utcOffsetHours: 0),
  CountryOption(name: '프랑스', code: 'FR', flag: '🇫🇷', utcOffsetHours: 1),
  CountryOption(name: '스위스', code: 'CH', flag: '🇨🇭', utcOffsetHours: 1),
  CountryOption(name: '이탈리아', code: 'IT', flag: '🇮🇹', utcOffsetHours: 1),
  CountryOption(name: '스페인', code: 'ES', flag: '🇪🇸', utcOffsetHours: 1),
  CountryOption(name: '독일', code: 'DE', flag: '🇩🇪', utcOffsetHours: 1),
  CountryOption(name: '오스트리아', code: 'AT', flag: '🇦🇹', utcOffsetHours: 1),
  CountryOption(name: '네덜란드', code: 'NL', flag: '🇳🇱', utcOffsetHours: 1),
  CountryOption(name: '벨기에', code: 'BE', flag: '🇧🇪', utcOffsetHours: 1),
  CountryOption(name: '포르투갈', code: 'PT', flag: '🇵🇹', utcOffsetHours: 0),
  CountryOption(name: '체코', code: 'CZ', flag: '🇨🇿', utcOffsetHours: 1),
  CountryOption(name: '헝가리', code: 'HU', flag: '🇭🇺', utcOffsetHours: 1),
  CountryOption(name: '폴란드', code: 'PL', flag: '🇵🇱', utcOffsetHours: 1),
  CountryOption(name: '스웨덴', code: 'SE', flag: '🇸🇪', utcOffsetHours: 1),
  CountryOption(name: '노르웨이', code: 'NO', flag: '🇳🇴', utcOffsetHours: 1),
  CountryOption(name: '덴마크', code: 'DK', flag: '🇩🇰', utcOffsetHours: 1),
  CountryOption(name: '아이슬란드', code: 'IS', flag: '🇮🇸', utcOffsetHours: 0),
  CountryOption(name: '핀란드', code: 'FI', flag: '🇫🇮', utcOffsetHours: 2),
  CountryOption(name: '그리스', code: 'GR', flag: '🇬🇷', utcOffsetHours: 2),
  CountryOption(name: '미국', code: 'US', flag: '🇺🇸', utcOffsetHours: -5),
  CountryOption(name: '캐나다', code: 'CA', flag: '🇨🇦', utcOffsetHours: -5),
  CountryOption(name: '호주', code: 'AU', flag: '🇦🇺', utcOffsetHours: 10),
  CountryOption(name: '뉴질랜드', code: 'NZ', flag: '🇳🇿', utcOffsetHours: 12),
];

CountryOption? countryByName(String name) {
  final trimmed = name.trim();
  for (final country in countryOptions) {
    if (country.name == trimmed || country.code == trimmed.toUpperCase()) {
      return country;
    }
  }
  return null;
}

String countryFlags(Iterable<String> countries, {int max = 3}) {
  final flags = countries
      .map(countryByName)
      .whereType<CountryOption>()
      .map((country) => country.flag)
      .take(max)
      .join(' ');
  return flags;
}
