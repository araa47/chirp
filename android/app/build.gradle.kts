import java.security.MessageDigest

plugins { alias(libs.plugins.android.application); alias(libs.plugins.compose) }
android {
    buildFeatures { compose = true; buildConfig = true }
    namespace = "dev.chirp.android"
    compileSdk { version = release(37) { minorApiLevel = 2 } }
    buildToolsVersion = "37.0.0"
    ndkVersion = "28.0.13004108"
    packaging { jniLibs { useLegacyPackaging = true } }
    // Phones install the arm64 APK; the x86_64 split exists only for emulator validation.
    splits {
        abi {
            isEnable = true
            reset()
            include("arm64-v8a", "x86_64")
            isUniversalApk = false
        }
    }
    defaultConfig {
        applicationId = "dev.chirp.android"
        minSdk = 31
        targetSdk = 37
        versionCode = 15
        versionName = "0.7.3"
    }
    signingConfigs {
        create("local") {
            storeFile = rootProject.file("keystore/local-debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }
    // The dev-only key is per checkout (scripts/make-keystore.sh, gitignored); without it the release APK is unsigned.
    val localKeystore = rootProject.file("keystore/local-debug.keystore")
    if (localKeystore.exists()) buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("local")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), rootProject.file("keyboard/upstream/app/proguard-rules.pro"), "proguard-rules.pro")
        }
        release {
            signingConfig = signingConfigs.getByName("local")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), rootProject.file("keyboard/upstream/app/proguard-rules.pro"), "proguard-rules.pro")
        }
    }
    else logger.warn("keystore/local-debug.keystore missing: release APK will be unsigned (run scripts/make-keystore.sh)")
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    lint { warningsAsErrors = true; lintConfig = file("lint.xml") }
    testOptions { unitTests.isIncludeAndroidResources = true }
    sourceSets.getByName("debug").res.directories.add(layout.buildDirectory.dir("generated/chirp-debug-res").get().asFile.path)
}
// Personal builds only: -Pchirp.gestureLib=<Google's arm64 libjni_latinimegoogle.so> packages it as
// lib/arm64-v8a/libjni_latinimegoogle.so, which HeliBoard's JniUtils loads with no Swipe typing import.
// Never publish such an APK (README "Swipe typing"); the file must be HeliBoard's known arm64 release.
providers.gradleProperty("chirp.gestureLib").orNull?.let { path ->
    val gestureLib = file(path)
    require(gestureLib.isFile) { "chirp.gestureLib: $gestureLib is not a file" }
    val known = "b1049983e6ac5cfc6d1c66e38959751044fad213dff0637a6cf1d2a2703e754f" // JniUtils.CHECKSUM_ARM64
    val actual = MessageDigest.getInstance("SHA-256").digest(gestureLib.readBytes()).joinToString("") { "%02x".format(it) }
    require(actual == known) { "chirp.gestureLib: SHA-256 $actual of $gestureLib is not HeliBoard's known arm64 gesture library" }
    val jniDir = layout.buildDirectory.dir("generated/chirp-gesture-jni")
    val stageGestureLib = tasks.register<Sync>("stageGestureLib") {
        from(gestureLib) { rename { "libjni_latinimegoogle.so" } }
        into(jniDir.map { it.dir("arm64-v8a") })
    }
    android.sourceSets.getByName("main").jniLibs.directories.add(jniDir.get().asFile.path)
    tasks.matching { it.name.startsWith("merge") && it.name.endsWith("JniLibFolders") }.configureEach { dependsOn(stageGestureLib) }
    logger.lifecycle("chirp.gestureLib: packaging $gestureLib into the arm64 APK (personal build, do not publish)")
}
dependencies {
    implementation(project(":keyboard"))
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.material3)
    implementation(libs.compose.material3.navigation.suite)
    implementation(libs.activity.compose)
    implementation(libs.material)
    testImplementation(platform(libs.compose.bom))
    testImplementation(libs.compose.ui.test)
    // Compose pulls Espresso 3.5; use stable 3.7 for modern InputManager APIs.
    testImplementation(libs.espresso.core)
    debugImplementation(libs.compose.ui.test.manifest)
    implementation(libs.okhttp)
    implementation(libs.core)
    implementation(libs.activity)
    implementation(libs.coroutines)
    implementation(libs.code.scanner)
    constraints {
        implementation(libs.fragment) { because("Play services brings an old Fragment incompatible with Activity Result APIs") }
    }
    testImplementation(libs.junit)
    testImplementation(libs.json)
    testImplementation(libs.mockwebserver)
    testImplementation(libs.okhttp.tls)
    testImplementation(libs.robolectric)
}

// Opt-in live transport check against a running chirp-server (see README "JVM live check").
// Without -Pchirp.live.url the LiveServerTest is skipped.
// Robolectric renders go to build/screenshots, so a test run never rewrites the committed PNGs with rendering noise.
// Refresh docs/screenshots/android on purpose with -Pchirp.updateScreenshots.
val updateScreenshots = providers.gradleProperty("chirp.updateScreenshots").isPresent
tasks.withType<Test>().configureEach {
    systemProperty("chirp.screenshots", (if (updateScreenshots) rootProject.file("../docs/screenshots/android")
        else layout.buildDirectory.dir("screenshots").get().asFile).absolutePath)
    // Robolectric on JDK 17+: https://robolectric.org/getting-started/#running-with-java-17-and-higher
    jvmArgs(
        "--add-opens=java.base/java.lang=ALL-UNNAMED",
        "--add-opens=java.base/java.util=ALL-UNNAMED",
        "--add-opens=java.base/java.io=ALL-UNNAMED",
        "--add-opens=java.base/java.net=ALL-UNNAMED",
        "--add-opens=java.base/java.security=ALL-UNNAMED",
        "--add-opens=java.base/java.text=ALL-UNNAMED",
        "--add-opens=java.base/jdk.internal.access=ALL-UNNAMED",
        "--add-opens=java.desktop/java.awt.font=ALL-UNNAMED",
        "--add-opens=jdk.compiler/com.sun.tools.javac.api=ALL-UNNAMED",
    )
    listOf("chirp.live.url", "chirp.live.tokenFile", "chirp.live.wav", "chirp.live.expect").forEach { key ->
        providers.gradleProperty(key).orNull?.let { systemProperty(key, it) }
    }
}

val generateDebugSyntheticAudio by tasks.registering(Exec::class) {
    commandLine("sh", rootProject.file("scripts/make-synthetic-wav.sh"))
    outputs.dir(layout.buildDirectory.dir("generated/chirp-debug-assets"))
}
val generateEmulatorTls by tasks.registering(Exec::class) {
    outputs.upToDateWhen { false } // Renew the disposable test certificate before expiry.
    commandLine("sh", rootProject.file("scripts/make-emulator-tls.sh"))
    outputs.dir(layout.buildDirectory.dir("generated/chirp-debug-res"))
    outputs.dir(layout.buildDirectory.dir("emulator-tls"))
}
tasks.matching { it.name == "preDebugBuild" }.configureEach { dependsOn(generateEmulatorTls) }
tasks.matching { it.name == "mergeDebugAssets" || it.name == "packageDebugUnitTestForUnitTest" }.configureEach {
    dependsOn(generateDebugSyntheticAudio)
}

// Android 15+ may use 16 KB pages: packaged .so files need 16 KB-aligned LOAD segments
// and the APK zip layout must satisfy zipalign -P 16 (scripts/check-native-alignment.py).
listOf("Debug", "Release").forEach { variant ->
    val checkNative16k = tasks.register<Exec>("check${variant}Native16kAlignment") {
        commandLine(
            "python3", rootProject.file("scripts/check-native-alignment.py").absolutePath,
            layout.buildDirectory.dir("outputs/apk/${variant.lowercase()}").get().asFile.absolutePath,
        )
    }
    tasks.matching { it.name == "assemble$variant" }.configureEach { finalizedBy(checkNative16k) }
}
