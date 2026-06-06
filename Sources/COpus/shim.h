/* libopus Swift bridging header.
 *
 * Homebrew インストールの opus を SwiftPM systemLibrary 経由で使う。
 *   /opt/homebrew/include/opus/  (Apple Silicon)
 *   /usr/local/include/opus/     (Intel)
 *
 * Swift は C 可変長関数 (opus_encoder_ctl / opus_decoder_ctl) を直接
 * 呼べないので、ここで非可変長の inline ラッパを定義して expose する。
 */
#ifndef COPUS_SHIM_H
#define COPUS_SHIM_H

#include <opus.h>

/** opus_encoder_ctl(enc, request, int32) の非可変長ラッパ。
 *  例: copus_encoder_set_int(enc, OPUS_SET_BITRATE_REQUEST, 32000)
 */
static inline int copus_encoder_set_int(OpusEncoder *enc, int request, opus_int32 value) {
    return opus_encoder_ctl(enc, request, value);
}

/** opus_encoder_ctl(enc, request, *out) の非可変長ラッパ（int32 取得用）。*/
static inline int copus_encoder_get_int(OpusEncoder *enc, int request, opus_int32 *out) {
    return opus_encoder_ctl(enc, request, out);
}

/** opus_decoder_ctl(dec, request, int32) の非可変長ラッパ。*/
static inline int copus_decoder_set_int(OpusDecoder *dec, int request, opus_int32 value) {
    return opus_decoder_ctl(dec, request, value);
}

#endif /* COPUS_SHIM_H */
