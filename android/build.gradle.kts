allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    // permission_handler_android asks for compileSdk 37 ("android-37"), but the SDK
    // installs that platform as "android-37.0"; point it at the installed one.
    afterEvaluate {
        if (name == "permission_handler_android") {
            extensions.findByType(com.android.build.gradle.BaseExtension::class.java)?.compileSdkVersion("android-37.0")
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
