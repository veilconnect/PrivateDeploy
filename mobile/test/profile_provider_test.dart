import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:privatedeploy_mobile/features/profiles/profile_provider.dart';
import 'package:privatedeploy_mobile/core/network/api_client.dart';

@GenerateMocks([ApiClient])
import 'profile_provider_test.mocks.dart';

void main() {
  late ProfileProvider profileProvider;
  late MockApiClient mockApiClient;

  setUp(() {
    mockApiClient = MockApiClient();
    profileProvider = ProfileProvider(mockApiClient);
  });

  group('ProfileProvider Tests', () {
    test('初始状态应该是空列表', () {
      expect(profileProvider.profiles, isEmpty);
      expect(profileProvider.activeProfile, isNull);
    });

    test('加载配置文件列表成功', () async {
      // Arrange
      when(mockApiClient.getProfiles()).thenAnswer(
        (_) async => {
          'success': true,
          'data': [
            {
              'id': '1',
              'name': 'Profile 1',
              'is_active': true,
              'created_at': '2024-01-01T00:00:00Z',
              'updated_at': '2024-01-01T00:00:00Z',
            },
            {
              'id': '2',
              'name': 'Profile 2',
              'is_active': false,
              'created_at': '2024-01-01T00:00:00Z',
              'updated_at': '2024-01-01T00:00:00Z',
            }
          ]
        },
      );

      // Act
      await profileProvider.loadProfiles();

      // Assert
      expect(profileProvider.profiles.length, 2);
      expect(profileProvider.profiles[0].name, 'Profile 1');
      expect(profileProvider.profiles[0].isActive, true);
      verify(mockApiClient.getProfiles()).called(1);
    });

    test('创建配置文件成功', () async {
      // Arrange
      when(mockApiClient.createProfile(any)).thenAnswer(
        (_) async => {'success': true},
      );
      when(mockApiClient.getProfiles()).thenAnswer(
        (_) async => {
          'success': true,
          'data': [
            {
              'id': '1',
              'name': 'New Profile',
              'is_active': false,
              'created_at': '2024-01-01T00:00:00Z',
              'updated_at': '2024-01-01T00:00:00Z',
            }
          ]
        },
      );

      // Act
      final result = await profileProvider.createProfile(
        name: 'New Profile',
      );

      // Assert
      expect(result, true);
      verify(mockApiClient.createProfile(any)).called(1);
      verify(mockApiClient.getProfiles()).called(1);
    });

    test('删除配置文件成功', () async {
      // Arrange
      profileProvider.profiles.add(
        Profile(
          id: '1',
          name: 'Test Profile',
          isActive: false,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      when(mockApiClient.deleteProfile('1')).thenAnswer(
        (_) async => {'success': true},
      );

      // Act
      final result = await profileProvider.deleteProfile('1');

      // Assert
      expect(result, true);
      expect(profileProvider.profiles, isEmpty);
      verify(mockApiClient.deleteProfile('1')).called(1);
    });

    test('激活配置文件成功', () async {
      // Arrange
      profileProvider.profiles.addAll([
        Profile(
          id: '1',
          name: 'Profile 1',
          isActive: false,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
        Profile(
          id: '2',
          name: 'Profile 2',
          isActive: false,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ]);

      when(mockApiClient.setActiveProfile('2')).thenAnswer(
        (_) async => {'success': true},
      );

      // Act
      final result = await profileProvider.activateProfile('2');

      // Assert
      expect(result, true);
      expect(profileProvider.activeProfile?.id, '2');
      verify(mockApiClient.setActiveProfile('2')).called(1);
    });

    test('更新订阅成功', () async {
      // Arrange
      when(mockApiClient.updateSubscription('1')).thenAnswer(
        (_) async => {'success': true},
      );
      when(mockApiClient.getProfiles()).thenAnswer(
        (_) async => {'success': true, 'data': []},
      );

      // Act
      final result = await profileProvider.updateSubscription('1');

      // Assert
      expect(result, true);
      verify(mockApiClient.updateSubscription('1')).called(1);
    });

    test('获取配置文件内容成功', () async {
      // Arrange
      const content = '{"key": "value"}';
      when(mockApiClient.getProfileContent('1')).thenAnswer(
        (_) async => {'success': true, 'data': content},
      );

      // Act
      final result = await profileProvider.getProfileContent('1');

      // Assert
      expect(result, content);
      verify(mockApiClient.getProfileContent('1')).called(1);
    });

    test('保存配置文件内容成功', () async {
      // Arrange
      const content = '{"key": "value"}';
      when(mockApiClient.saveProfileContent('1', any)).thenAnswer(
        (_) async => {'success': true},
      );

      // Act
      final result = await profileProvider.saveProfileContent('1', content);

      // Assert
      expect(result, true);
      verify(mockApiClient.saveProfileContent('1', any)).called(1);
    });

    test('API 调用失败应该设置错误信息', () async {
      // Arrange
      when(mockApiClient.getProfiles()).thenAnswer(
        (_) async => {'success': false, 'message': 'Network error'},
      );

      // Act
      await profileProvider.loadProfiles();

      // Assert
      expect(profileProvider.error, 'Network error');
      expect(profileProvider.profiles, isEmpty);
    });
  });

  group('Profile Model Tests', () {
    test('应该从 JSON 正确创建 Profile', () {
      final json = {
        'id': '123',
        'name': 'Test Profile',
        'subscription_url': 'https://example.com/sub',
        'is_active': true,
        'created_at': '2024-01-01T00:00:00Z',
        'updated_at': '2024-01-02T00:00:00Z',
        'last_updated': '2024-01-03T00:00:00Z',
      };

      final profile = Profile.fromJson(json);

      expect(profile.id, '123');
      expect(profile.name, 'Test Profile');
      expect(profile.subscriptionUrl, 'https://example.com/sub');
      expect(profile.isActive, true);
    });

    test('应该正确转换为 JSON', () {
      final profile = Profile(
        id: '123',
        name: 'Test Profile',
        subscriptionUrl: 'https://example.com/sub',
        isActive: true,
        createdAt: DateTime.parse('2024-01-01T00:00:00Z'),
        updatedAt: DateTime.parse('2024-01-02T00:00:00Z'),
      );

      final json = profile.toJson();

      expect(json['id'], '123');
      expect(json['name'], 'Test Profile');
      expect(json['subscription_url'], 'https://example.com/sub');
      expect(json['is_active'], true);
    });
  });

  tearDown(() {
    profileProvider.dispose();
  });
}
