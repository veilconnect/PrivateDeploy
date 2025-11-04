#!/bin/bash

# PrivateDeploy Mobile Initialization Script
# This script initializes the Flutter mobile project

set -e

echo "======================================"
echo "  PrivateDeploy Mobile Initialization"
echo "======================================"
echo ""

# Check if Flutter is installed
if ! command -v flutter &> /dev/null; then
    echo "❌ Flutter is not installed!"
    echo ""
    echo "Please install Flutter first:"
    echo "  https://docs.flutter.dev/get-started/install"
    echo ""
    exit 1
fi

echo "✅ Flutter detected: $(flutter --version | head -1)"
echo ""

# Check Flutter installation
echo "📋 Running Flutter doctor..."
flutter doctor
echo ""

# Navigate to project root
cd "$(dirname "$0")"

# Check if mobile directory already exists
if [ -d "mobile" ]; then
    echo "⚠️  Warning: mobile/ directory already exists"
    read -p "Do you want to recreate it? (y/N): " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        rm -rf mobile
    else
        echo "Exiting..."
        exit 0
    fi
fi

# Create Flutter project
echo "📱 Creating Flutter project..."
flutter create mobile \
    --org com.privatedeploy \
    --project-name privatedeploy \
    --platforms android,ios \
    --description "PrivateDeploy mobile app for VPN management"

echo ""
echo "✅ Flutter project created successfully"
echo ""

# Navigate to mobile directory
cd mobile

# Add dependencies
echo "📦 Adding dependencies..."
flutter pub add \
    flutter_screenutil \
    flutter_svg \
    provider \
    dio \
    retrofit \
    web_socket_channel \
    hive \
    hive_flutter \
    shared_preferences \
    intl \
    logger \
    path_provider \
    permission_handler \
    flutter_local_notifications \
    package_info_plus

# Add dev dependencies
flutter pub add --dev \
    build_runner \
    retrofit_generator \
    hive_generator \
    json_serializable

echo ""
echo "✅ Dependencies added successfully"
echo ""

# Create directory structure
echo "📁 Creating project structure..."

mkdir -p lib/core/{network,storage,vpn,constants}
mkdir -p lib/features/{auth,home,cloud,profile,subscription,settings}/{data,domain,presentation}
mkdir -p lib/shared/{widgets,utils,models}
mkdir -p assets/{images,i18n}

echo ""
echo "✅ Project structure created"
echo ""

# Create core files
echo "📝 Creating core files..."

# API constants
cat > lib/core/constants/api_constants.dart << 'EOF'
class ApiConstants {
  // Development
  static const String devBaseUrl = 'http://10.0.2.2:8443'; // Android emulator
  static const String devWsUrl = 'ws://10.0.2.2:8443/api/v1/ws';

  // Production
  static const String prodBaseUrl = 'https://api.privatedeploy.com';
  static const String prodWsUrl = 'wss://api.privatedeploy.com/api/v1/ws';

  // Current environment
  static const bool isProduction = false;
  static String get baseUrl => isProduction ? prodBaseUrl : devBaseUrl;
  static String get wsUrl => isProduction ? prodWsUrl : devWsUrl;

  // API endpoints
  static const String login = '/api/v1/auth/login';
  static const String refresh = '/api/v1/auth/refresh';
  static const String systemInfo = '/api/v1/system/info';
  static const String profiles = '/api/v1/profiles';
  static const String subscriptions = '/api/v1/subscriptions';
  static const String vpnStart = '/api/v1/vpn/start';
  static const String vpnStop = '/api/v1/vpn/stop';
  static const String vpnStatus = '/api/v1/vpn/status';
}
EOF

echo "✅ Core files created"
echo ""

# Run flutter pub get
echo "📥 Getting dependencies..."
flutter pub get

echo ""
echo "======================================"
echo "  🎉 Initialization Complete!"
echo "======================================"
echo ""
echo "Next steps:"
echo "  1. cd mobile"
echo "  2. flutter doctor (check environment)"
echo "  3. flutter devices (check available devices)"
echo "  4. flutter run (run the app)"
echo ""
echo "For more information, see mobile/README.md"
echo ""
