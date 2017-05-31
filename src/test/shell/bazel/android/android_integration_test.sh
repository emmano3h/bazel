#!/bin/bash
#
# Copyright 2015 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# For this tests to run do the following:
# 1. Uncomment the 2 lines regarding android integration tests in the WORKSPACE
# file.
# 2. Set the environment variables ANDROID_HOME and ANDROID_NDK accordingly to
# your Android SDK and NDK home directories.
# 3. Run scripts/workspace_user.sh.
#
# Note that if the environment is not set up as above android_integration_test
# will silently be ignored and will be shown as passing.

# Load the test setup defined in the parent directory
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${CURRENT_DIR}/../../integration_test_setup.sh" \
  || { echo "integration_test_setup.sh not found!" >&2; exit 1; }


function create_android_binary() {
  mkdir -p java/bazel
  cat > java/bazel/BUILD <<EOF
android_library(
    name = "lib",
    srcs = ["Lib.java"],
)

android_binary(
    name = "bin",
    srcs = [
        "MainActivity.java",
        "Jni.java",
    ],
    legacy_native_support = 0,
    manifest = "AndroidManifest.xml",
    deps = [
        ":lib",
        ":jni"
    ],
)

cc_library(
    name = "jni",
    srcs = ["jni.cc"],
    deps = [":jni_dep"],
)

cc_library(
    name = "jni_dep",
    srcs = ["jni_dep.cc"],
    hdrs = ["jni_dep.h"],
)

EOF

  cat > java/bazel/AndroidManifest.xml <<EOF
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="bazel.android"
    android:versionCode="1"
    android:versionName="1.0" >

    <uses-sdk
        android:minSdkVersion="21"
        android:targetSdkVersion="21" />

    <application
        android:label="Bazel Test App" >
        <activity
            android:name="bazel.MainActivity"
            android:label="Bazel" >
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
EOF

  cat > java/bazel/Lib.java <<EOF
package bazel;

public class Lib {
  public static String message() {
    return "Hello Lib";
  }
}
EOF

  cat > java/bazel/Jni.java <<EOF
package bazel;

public class Jni {
  public static native String hello();
}

EOF
  cat > java/bazel/MainActivity.java <<EOF
package bazel;

import android.app.Activity;
import android.os.Bundle;

public class MainActivity extends Activity {
  @Override
  public void onCreate(Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);
  }
}
EOF

  cat > java/bazel/jni_dep.h <<EOF
#pragma once

#include <jni.h>

jstring NewStringLatin1(JNIEnv *env, const char *str);
EOF

  cat > java/bazel/jni_dep.cc <<EOF
#include "java/bazel/jni_dep.h"

#include <stdlib.h>
#include <string.h>

jstring NewStringLatin1(JNIEnv *env, const char *str) {
  int len = strlen(str);
  jchar *str1;
  str1 = reinterpret_cast<jchar *>(malloc(len * sizeof(jchar)));

  for (int i = 0; i < len; i++) {
    str1[i] = (unsigned char)str[i];
  }
  jstring result = env->NewString(str1, len);
  free(str1);
  return result;
}
EOF

  cat > java/bazel/jni.cc <<EOF
#include <jni.h>
#include <string>

#include "java/bazel/jni_dep.h"

extern "C" JNIEXPORT jstring JNICALL
Java_bazel_Jni_hello(JNIEnv *env, jclass clazz) {
  std::string hello = "Hello";
  std::string jni = "JNI";
  return NewStringLatin1(env, (hello + " " + jni).c_str());
}
EOF
}

function check_num_sos() {
  num_sos=$(unzip -Z1 bazel-bin/java/bazel/bin.apk '*.so' | wc -l | sed -e 's/[[:space:]]//g')
  assert_equals "7" "$num_sos"
}

function check_soname() {
  # For an android_binary with name foo, readelf output format is
  #  Tag        Type          Name/Value
  # 0x00000010 (SONAME)       Library soname: [libfoo]
  #
  # If -Wl,soname= is not set, then SONAME will not appear in the output.
  #
  # readelf is a Linux utility and not available on Mac by default. The NDK
  # includes readelf however the path is difference for Mac vs Linux, hence the
  # star.
  readelf="${TEST_SRCDIR}/androidndk/ndk/toolchains/arm-linux-androideabi-4.9/prebuilt/*/bin/arm-linux-androideabi-readelf"
  soname=$($readelf -d bazel-bin/java/bazel/_dx/bin/native_symlinks/x86/libbin.so \
    | grep SONAME \
    | awk '{print substr($5,2,length($5)-2)}')
  assert_equals "libbin" "$soname"
}

function test_sdk_library_deps() {
  create_new_workspace
  setup_android_sdk_support

  mkdir -p java/a
  cat > java/a/BUILD<<EOF
android_library(
    name = "a",
    deps = ["@androidsdk//com.android.support:mediarouter-v7-24.0.0"],
)
EOF

  bazel build --nobuild //java/a:a || fail "build failed"
}

function test_android_binary() {
  create_new_workspace
  setup_android_sdk_support
  setup_android_ndk_support
  create_android_binary

  cpus="armeabi,armeabi-v7a,arm64-v8a,mips,mips64,x86,x86_64"

  bazel build -s //java/bazel:bin --fat_apk_cpu="$cpus" || fail "build failed"
  check_num_sos
  check_soname
}

is_ndk_10() {
  if [[ -r "${BAZEL_RUNFILES}/external/androidndk/ndk/source.properties" ]]; then
    return 1
  else
    return 0
  fi
}

function test_android_binary_clang() {
  # clang3.8 is only available on NDK r11
  if is_ndk_10; then
    echo "Not running test_android_binary_clang because it requires NDK11 or later"
    return
  fi
  create_new_workspace
  setup_android_sdk_support
  setup_android_ndk_support
  create_android_binary

  cpus="armeabi,armeabi-v7a,arm64-v8a,mips,mips64,x86,x86_64"

  bazel build -s //java/bazel:bin \
      --fat_apk_cpu="$cpus" \
      --android_compiler=clang3.8 \
      || fail "build failed"
  check_num_sos
  check_soname
}

# Regression test for https://github.com/bazelbuild/bazel/issues/2601.
function test_clang_include_paths() {
  if is_ndk_10; then
    echo "Not running test_clang_include_paths because it requires NDK11 or later"
    return
  fi
  create_new_workspace
  setup_android_ndk_support
  cat > BUILD <<EOF
cc_binary(
    name = "foo",
    srcs = ["foo.cc"],
    copts = ["-mfpu=neon"],
)
EOF
  cat > foo.cc <<EOF
#include <arm_neon.h>
int main() { return 0; }
EOF
  bazel build //:foo \
    --compiler=clang3.8 \
    --cpu=armeabi-v7a \
    --crosstool_top=//external:android/crosstool \
    --host_crosstool_top=@bazel_tools//tools/cpp:toolchain \
    || fail "build failed"
}

# Regression test for https://github.com/bazelbuild/bazel/issues/1928.
function test_empty_tree_artifact_action_inputs_mount_empty_directories() {
  create_new_workspace
  setup_android_sdk_support
  cat > AndroidManifest.xml <<EOF
<manifest package="com.test"/>
EOF
  mkdir res
  zip test.aar AndroidManifest.xml res/
  cat > BUILD <<EOF
aar_import(
  name = "test",
  aar = "test.aar",
)
EOF
  # Building aar_import invokes the AndroidResourceProcessingAction with a
  # TreeArtifact of the AAR resources as the input. Since there are no
  # resources, the Bazel sandbox should create an empty directory. If the
  # directory is not created, the action thinks that its inputs do not exist and
  # crashes.
  bazel build :test
}

function test_nonempty_aar_resources_tree_artifact() {
  create_new_workspace
  setup_android_sdk_support
  cat > AndroidManifest.xml <<EOF
<manifest package="com.test"/>
EOF
  mkdir -p res/values
  cat > res/values/values.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<resources xmlns:android="http://schemas.android.com/apk/res/android">
</resources>
EOF
  zip test.aar AndroidManifest.xml res/values/values.xml
  cat > BUILD <<EOF
aar_import(
  name = "test",
  aar = "test.aar",
)
EOF
  bazel build :test
}

function test_android_sdk_repository_path_from_environment() {
  create_new_workspace
  setup_android_sdk_support
  # Overwrite WORKSPACE that was created by setup_android_sdk_support with one
  # that does not set the path attribute of android_sdk_repository.
  cat > WORKSPACE <<EOF
android_sdk_repository(
    name = "androidsdk",
)
EOF
  ANDROID_HOME=$ANDROID_SDK bazel build @androidsdk//:files || fail \
    "android_sdk_repository failed to build with \$ANDROID_HOME instead of " \
    "path"
}

function test_android_ndk_repository_path_from_environment() {
  create_new_workspace
  setup_android_ndk_support
  cat > WORKSPACE <<EOF
android_ndk_repository(
    name = "androidndk",
    api_level = 25,
)
EOF
  ANDROID_NDK_HOME=$ANDROID_NDK bazel build @androidndk//:files || fail \
    "android_ndk_repository failed to build with \$ANDROID_NDK_HOME instead " \
    "of path"
}

function test_android_sdk_repository_no_path_or_android_home() {
  create_new_workspace
  cat > WORKSPACE <<EOF
android_sdk_repository(
    name = "androidsdk",
    api_level = 25,
)
EOF
  bazel build @androidsdk//:files >& $TEST_log && fail "Should have failed"
  expect_log "Either the path attribute of android_sdk_repository"
}

function test_android_ndk_repository_no_path_or_android_ndk_home() {
  create_new_workspace
  cat > WORKSPACE <<EOF
android_ndk_repository(
    name = "androidndk",
    api_level = 25,
)
EOF
  bazel build @androidndk//:files >& $TEST_log && fail "Should have failed"
  expect_log "Either the path attribute of android_ndk_repository"
}

# Check that the build succeeds if an android_sdk is specified with --android_sdk
function test_specifying_android_sdk_flag() {
  create_new_workspace
  setup_android_sdk_support
  setup_android_ndk_support
  create_android_binary
  cat > WORKSPACE <<EOF
android_sdk_repository(
    name = "a",
)
android_ndk_repository(
    name = "androidndk",
    api_level = 24,
)
EOF
  ANDROID_HOME=$ANDROID_SDK ANDROID_NDK_HOME=$ANDROID_NDK bazel build \
    --android_sdk=@a//:sdk-24 //java/bazel:bin || fail \
    "build with --android_sdk failed"
}

# Regression test for https://github.com/bazelbuild/bazel/issues/2621.
function test_android_sdk_repository_returns_null_if_env_vars_missing() {
  create_new_workspace
  setup_android_sdk_support
  ANDROID_HOME=/does_not_exist_1 bazel build @androidsdk//:files || \
    fail "Build failed"
  sed -i -e 's/path =/#path =/g' WORKSPACE
  ANDROID_HOME=/does_not_exist_2 bazel build @androidsdk//:files && \
    fail "Build should have failed"
  ANDROID_HOME=$ANDROID_SDK bazel build @androidsdk//:files || "Build failed"
}

# ndk r10 and earlier
if [[ ! -r "${TEST_SRCDIR}/androidndk/ndk/RELEASE.TXT" ]]; then
  # ndk r11 and later
  if [[ ! -r "${TEST_SRCDIR}/androidndk/ndk/source.properties" ]]; then
    echo "Not running Android tests due to lack of an Android NDK."
    exit 0
  fi
fi

if [[ ! -r "${TEST_SRCDIR}/androidsdk/tools/android" ]]; then
  echo "Not running Android tests due to lack of an Android SDK."
  exit 0
fi

run_suite "Android integration tests"
