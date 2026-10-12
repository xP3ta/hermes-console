import java.io.FileInputStream
import java.util.Properties

plugins {
   id("com.android.application")
   id("org.jetbrains.kotlin.plugin.compose")
   id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePath = rootProject.projectDir.parentFile.resolve("key.properties")
val hasReleaseKeystore = keystorePath.exists()
if (hasReleaseKeystore) {
   keystoreProperties.load(FileInputStream(keystorePath))
}

android {
   namespace = "com.hermesagent.hermes_android"
   compileSdk = 36

   compileOptions {
       sourceCompatibility = JavaVersion.VERSION_17
       targetCompatibility = JavaVersion.VERSION_17
       isCoreLibraryDesugaringEnabled = true
   }

   defaultConfig {
       // Identidad pública en Play (inmutable tras la primera publicación).
       // Propia de XPeta Lab para no colisionar con el package de Nous/Hermes.
       // El namespace interno no cambia: las clases Kotlin siguen donde están.
       applicationId = "dev.xpetalab.hermesconsole"
       minSdk = 24
       targetSdk = 36
       versionCode = flutter.versionCode
       versionName = flutter.versionName
   }

   signingConfigs {
       create("release") {
           if (keystoreProperties.containsKey("storeFile")) {
               storeFile = file(keystoreProperties["storeFile"] as String)
               storePassword = keystoreProperties["storePassword"] as String
               keyAlias = keystoreProperties["keyAlias"] as String
               keyPassword = keystoreProperties["keyPassword"] as String
           }
       }
   }

   // Flavors of the same code (see docs/RELEASE_DISTRIBUTION.md):
   //  - full -> direct download (GitHub Releases / Obtainium).
   //  - play -> Google Play.
   //  - qa   -> emulator testing, installed next to the Play build.
   // full and play share the production applicationId on purpose, so an
   // update keeps the installed app's data. They cannot be installed at the
   // same time, which is acceptable (full = direct, play = store).
   flavorDimensions += "distribution"
   productFlavors {
       create("full") {
           dimension = "distribution"
       }
       create("play") {
           dimension = "distribution"
       }
       create("qa") {
           dimension = "distribution"
           // La app instalada desde Play está firmada por Google y no puede
           // actualizarse por ADB con la upload/debug key. Este package aislado
           // permite probar el mismo código sin desinstalar ni perder datos.
           applicationIdSuffix = ".qa"
           versionNameSuffix = "-qa"
       }
   }

   buildTypes {
       release {
           // La validación de tareas al final del archivo impide empaquetar una
           // variante release sin la upload key. Nunca se degrada a firma debug.
           signingConfig = signingConfigs.getByName("release")
           isMinifyEnabled = true
           isShrinkResources = true
           // Incluye tablas de símbolos nativos en el AAB para que Play pueda
           // simbolicar fallos de Flutter/Whisper/Sherpa/ONNX sin distribuir
           // información de depuración en los APK instalados.
           ndk {
               debugSymbolLevel = "SYMBOL_TABLE"
           }
           proguardFiles(
               getDefaultProguardFile("proguard-android-optimize.txt"),
               "proguard-rules.pro",
           )
       }
   }
}

kotlin {
   compilerOptions {
       jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
   }
}

flutter {
   source = "../.."
}

dependencies {
   coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
   implementation("androidx.glance:glance-appwidget:1.1.1")
   // Live Updates (Android 16): NotificationCompat.ProgressStyle,
   // setRequestPromotedOngoing and canPostPromotedNotifications (core 1.17+).
   // The runtime classpath already resolves core 1.18 transitively.
   implementation("androidx.core:core-ktx:1.17.0")
   // home_widget already resolves this exact artifact transitively. Declaring
   // it here exposes the one-shot expiry API to the app without adding a new
   // binary, version or periodic background component.
   implementation("androidx.work:work-runtime-ktx:2.11.2")
}

val validateReleaseSigning by tasks.registering {
   doLast {
       if (!hasReleaseKeystore ||
           !keystoreProperties.containsKey("storeFile") ||
           !keystoreProperties.containsKey("keyAlias")) {
           throw GradleException(
               "Release signing is not configured. Add key.properties at the project root."
           )
       }
   }
}

tasks.configureEach {
   val packagesRelease =
       name.startsWith("bundle") || name.startsWith("assemble") || name.startsWith("package")
   if (packagesRelease && name.contains("Release")) {
       dependsOn(validateReleaseSigning)
   }
}
