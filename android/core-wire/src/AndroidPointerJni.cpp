#include <jni.h>
#include <superconnect_core.h>

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_receiver_PointerInputNative_encode(
    JNIEnv* env, jobject, jint type, jint tool, jint buttons, jlong timestamp,
    jfloat x, jfloat y, jfloat pressure, jfloat tiltX, jfloat tiltY) {
    ScInputEventV1 event{};
    event.struct_size = sizeof(event);
    event.api_version = SC_API_VERSION_V1;
    event.type = static_cast<uint8_t>(type);
    event.tool = static_cast<uint8_t>(tool);
    event.buttons = static_cast<uint8_t>(buttons);
    event.timestamp_ms = static_cast<uint64_t>(timestamp);
    event.x = x; event.y = y; event.pressure = pressure;
    event.tilt_x = tiltX; event.tilt_y = tiltY;
    uint8_t output[SC_INPUT_RECORD_V1_SIZE]{};
    size_t needed = 0;
    if (sc_input_encode_v1(&event, output, sizeof(output), &needed) != SC_OK) return nullptr;
    auto result = env->NewByteArray(static_cast<jsize>(needed));
    if (result) env->SetByteArrayRegion(result, 0, static_cast<jsize>(needed),
        reinterpret_cast<const jbyte*>(output));
    return result;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_superconnect_receiver_PointerInputNative_encodeKey(
    JNIEnv* env, jobject, jint type, jint keyCode, jint flags, jlong timestamp) {
    ScInputEventV1 event{};
    event.struct_size = sizeof(event); event.api_version = SC_API_VERSION_V1;
    event.type = static_cast<uint8_t>(type); event.flags = static_cast<uint8_t>(flags);
    event.key_code = static_cast<uint16_t>(keyCode);
    event.timestamp_ms = static_cast<uint64_t>(timestamp);
    uint8_t output[SC_INPUT_RECORD_V1_SIZE]{};
    size_t needed = 0;
    if (sc_input_encode_v1(&event, output, sizeof(output), &needed) != SC_OK) return nullptr;
    auto result = env->NewByteArray(static_cast<jsize>(needed));
    if (result) env->SetByteArrayRegion(result, 0, static_cast<jsize>(needed),
        reinterpret_cast<const jbyte*>(output));
    return result;
}
