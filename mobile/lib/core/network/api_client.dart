import 'package:dio/dio.dart';
import 'package:retrofit/retrofit.dart';

part 'api_client.g.dart';

@RestApi(baseUrl: "http://localhost:8443/api/v1")
abstract class ApiClient {
  factory ApiClient(Dio dio, {String baseUrl}) = _ApiClient;

  // Auth
  @POST("/auth/login")
  Future<Map<String, dynamic>> login(@Body() Map<String, dynamic> body);

  @POST("/auth/refresh")
  Future<Map<String, dynamic>> refreshToken();

  // Cloud
  @GET("/cloud/providers")
  Future<Map<String, dynamic>> getProviders();

  @GET("/cloud/config")
  Future<Map<String, dynamic>> getCloudConfig();

  @POST("/cloud/config")
  Future<Map<String, dynamic>> saveCloudConfig(@Body() Map<String, dynamic> config);

  @GET("/cloud/instances")
  Future<Map<String, dynamic>> getInstances();

  @POST("/cloud/instances")
  Future<Map<String, dynamic>> createInstance(@Body() Map<String, dynamic> options);

  @DELETE("/cloud/instances/{id}")
  Future<void> deleteInstance(@Path("id") String id);

  // Profiles
  @GET("/profiles")
  Future<Map<String, dynamic>> getProfiles();

  @POST("/profiles")
  Future<Map<String, dynamic>> createProfile(@Body() Map<String, dynamic> profile);

  @PUT("/profiles/{id}")
  Future<Map<String, dynamic>> updateProfile(
    @Path("id") int id,
    @Body() Map<String, dynamic> profile,
  );

  @DELETE("/profiles/{id}")
  Future<void> deleteProfile(@Path("id") int id);

  // Subscriptions
  @GET("/subscriptions")
  Future<Map<String, dynamic>> getSubscriptions();

  @POST("/subscriptions")
  Future<Map<String, dynamic>> createSubscription(@Body() Map<String, dynamic> subscription);

  @PUT("/subscriptions/{id}/refresh")
  Future<Map<String, dynamic>> refreshSubscription(@Path("id") int id);
}

class DioClient {
  static Dio createDio({String? token}) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 30),
        headers: {
          'Content-Type': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
      ),
    );

    // Add interceptors for logging
    dio.interceptors.add(LogInterceptor(
      requestBody: true,
      responseBody: true,
    ));

    return dio;
  }
}
