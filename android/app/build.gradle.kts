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

   // Variantes del mismo código (ver docs/RELEASE_DISTRIBUTION.md):
   //  · full → app completa con instancia local en Termux (descarga directa).
   //  · play → solo-remoto, sin la función local ni sus permisos (Google Play).
   //  · qa   → equivalente remoto para pruebas en emulador en paralelo a Play.
   // Ambas comparten applicationId de producción a propósito: así el build `full`
   // (el de uso diario) actualiza la app instalada sin perder datos. No conviven
   // a la vez en un mismo dispositivo, lo cual es aceptable (full = directo,
   // play = tienda). El gating de UI/permisos se hace por manifest (src/play) y
   // por kLocalAgentEnabled (--dart-define=HERMES_LOCAL_AGENT=true), habilitada
   // únicamente para el artefacto full.
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
