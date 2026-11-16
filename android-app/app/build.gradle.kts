import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

/*
 * Release signing. ATA is distributed as an APK from GitHub Releases (not Google Play), so this key is the app's
 * signing key: every release must be signed with it, or phones refuse to install the update over the old version.
 * The keystore and its passwords live outside the repo and are never committed. They are found through, in order:
 *   1. env ATA_SIGNING_STORE_FILE, ATA_SIGNING_STORE_PASSWORD, ATA_SIGNING_KEY_ALIAS, ATA_SIGNING_KEY_PASSWORD
 *      (CI: .github/workflows/release.yml, from repository secrets; no password is written to disk);
 *   2. a properties file (keys: storeFile, storePassword, keyAlias, keyPassword): Gradle property `ata.signing`,
 *      env ATA_SIGNING_PROPERTIES, then ~/ata-secrets/android/signing.properties.
 * Without either, the release build is produced unsigned (CI test builds and other machines still build).
 *
 * Version: -Pata.versionCode=<n> -Pata.versionName=<x.y.z> (CI sets both from the run number, so every published
 * build has a higher versionCode than the one before). Local builds default to 1 / "1.0.0".
 */
val signingProps: Properties? = run {
    val env = System.getenv()
    if (!env["ATA_SIGNING_STORE_FILE"].isNullOrEmpty()) {
        return@run Properties().apply {
            setProperty("storeFile", env.getValue("ATA_SIGNING_STORE_FILE"))
            setProperty("storePassword", env["ATA_SIGNING_STORE_PASSWORD"].orEmpty())
            setProperty("keyAlias", env["ATA_SIGNING_KEY_ALIAS"].orEmpty())
            setProperty("keyPassword", env["ATA_SIGNING_KEY_PASSWORD"].orEmpty())
        }
    }
    val path = (findProperty("ata.signing") as String?)
        ?: System.getenv("ATA_SIGNING_PROPERTIES")
        ?: "${System.getProperty("user.home")}/ata-secrets/android/signing.properties"
    val f = file(path)
    if (f.isFile) Properties().apply { f.inputStream().use { load(it) } } else null
}

android {
    namespace = "io.github.magiclin99.ata"
    compileSdk = 36
    buildToolsVersion = "36.0.0"

    defaultConfig {
        applicationId = "io.github.magiclin99.ata"
        minSdk = 28
        targetSdk = 36
        versionCode = (findProperty("ata.versionCode") as String?)?.toInt() ?: 1
        versionName = (findProperty("ata.versionName") as String?) ?: "1.0.0"
        // libwebrtc is native. The artifact ships arm64-v8a (16 KB-aligned) and armeabi-v7a; x86/x86_64 are
        // emulator/Chromebook only and are left out. The published APK carries both.
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }

        // Reserved voluntary-donation entry. SUPPORT_URL is empty by default, and while it
        // is empty nothing is shown anywhere. Even with a URL, the "Support ATA" row stays hidden unless
        // SHOW_SUPPORT_LINK is true. Off by default; it is an owner decision to turn on (and if ATA is ever offered on
        // Google Play, its Payments policy on in-app links to outside payment pages must be re-checked first).
        // A donation never unlocks anything. Override with -Pata.supportUrl=https://… -Pata.showSupportLink=true.
        buildConfigField("String", "SUPPORT_URL", "\"${(findProperty("ata.supportUrl") as String?).orEmpty()}\"")
        buildConfigField("boolean", "SHOW_SUPPORT_LINK", (findProperty("ata.showSupportLink") as String?)?.toBoolean()?.toString() ?: "false")
    }

    signingConfigs {
        if (signingProps != null) {
            create("release") {
                storeFile = file(signingProps.getProperty("storeFile"))
                storePassword = signingProps.getProperty("storePassword")
                keyAlias = signingProps.getProperty("keyAlias")
                keyPassword = signingProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release")
        }
    }

    bundle {
        // Language splits stay on so each install gets only zh-TW or en strings; ABI and density splits as default.
        language { enableSplit = true }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
        unitTests.all { test ->
            // Opt in to the layout screenshots: ./gradlew :app:testDebugUnitTest -Pata.screenshots
            test.systemProperty("ata.screenshots", (findProperty("ata.screenshots") != null).toString())
            test.systemProperty("ata.screenshotDir", layout.buildDirectory.dir("screenshots").get().asFile.path)
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        resources.excludes += listOf("META-INF/*.kotlin_module", "META-INF/versions/**", "DebugProbesKt.bin")
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(project(":core"))

    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")

    implementation(platform("androidx.compose:compose-bom:2025.10.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    debugImplementation("androidx.compose.ui:ui-tooling")
    implementation("androidx.compose.ui:ui-tooling-preview")

    // Pairing QR code: CameraX preview + ZXing decoder, entirely on device (no ML Kit / Play services SDK, which
    // would send Google diagnostics). CAMERA is requested only when the user taps "Scan QR code".
    implementation("androidx.camera:camera-camera2:1.6.2")
    implementation("androidx.camera:camera-lifecycle:1.6.2")
    implementation("androidx.camera:camera-view:1.6.2")
    implementation("com.google.zxing:core:3.5.4")
    // Google libwebrtc packaged by Stream (org.webrtc API); device-verified in the v1 lab.
    implementation("io.getstream:stream-webrtc-android:1.3.10")

    testImplementation("junit:junit:4.13.2")
    // Layout screenshots of the wording at several widths and font sizes (opt-in, see LayoutScreenshotTest).
    testImplementation("org.robolectric:robolectric:4.18")
    testImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
