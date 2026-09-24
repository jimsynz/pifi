/*
 * An ALAC decoder for the BEAM.
 *
 * The decoding is David Hammerton's, in alac.c beside this, with the bounds checks that
 * file needed to be fed by a network rather than by a file. This is the part that hands
 * frames to it and gives the samples back as a binary.
 *
 * A decoder is a resource rather than a process. It holds the rice parameters and the
 * working buffers for one stream, and a stream is one AirPlay session: making one for
 * each frame would throw away that state and allocate on every packet of the audio.
 *
 * alac_decode_frame writes to a buffer the caller owns, and it reads *outputsize as the
 * room available before it writes anything. Passing zero there answers
 * "Not enough space in the output buffer" and decodes nothing at all, which is a
 * silence rather than an error.
 */

#include <erl_nif.h>
#include <string.h>
#include "alac.h"

/* A frame is at most 4096 samples of 2 channels at 4 bytes, which is what the largest
   ALACSpecificConfig a sender may send asks for. */
#define MAX_FRAME_SAMPLES 4096
#define MAX_CHANNELS 2
#define MAX_FRAME_BYTES (MAX_FRAME_SAMPLES * MAX_CHANNELS * 4)

/* What alac_set_info reads past before the ALACSpecificConfig begins. It is the
   wrapping of an old QuickTime atom and the decoder skips it without looking. */
#define COOKIE_PREFIX 24
#define COOKIE_CONFIG 24

static ErlNifResourceType *DECODER;

typedef struct {
  alac_file *alac;
  unsigned char *out;
} decoder;

static void decoder_free(ErlNifEnv *env, void *object) {
  (void)env;
  decoder *d = (decoder *)object;

  if (d->alac) alac_free(d->alac);
  if (d->out) enif_free(d->out);
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
  (void)priv;
  (void)info;

  DECODER = enif_open_resource_type(env, NULL, "alac_decoder", decoder_free,
                                    ERL_NIF_RT_CREATE, NULL);

  return DECODER == NULL ? 1 : 0;
}

/* start(config, sample_size, channels) -> {:ok, decoder} */
static ERL_NIF_TERM start(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  ErlNifBinary config;
  int sample_size, channels;

  if (!enif_inspect_binary(env, argv[0], &config) ||
      !enif_get_int(env, argv[1], &sample_size) ||
      !enif_get_int(env, argv[2], &channels)) {
    return enif_make_badarg(env);
  }

  if (config.size != COOKIE_CONFIG) return enif_make_badarg(env);

  /* The frame length is the first four bytes of the config, and a sender chooses it.
     Everything downstream is sized from it: alac_allocate_buffers multiplies it by four,
     and the guard inside alac_decode_frame multiplies it by the bytes per sample, both
     in an int that a large value overflows — so an absurd length here wraps those to
     small numbers and the decoder then writes past buffers it thinks are big enough.
     The output buffer below is a fixed MAX_FRAME_BYTES, so this is also the bound that
     makes that size correct. */
  uint32_t frame_length = ((uint32_t)config.data[0] << 24) | ((uint32_t)config.data[1] << 16) |
                          ((uint32_t)config.data[2] << 8) | (uint32_t)config.data[3];

  if (frame_length == 0 || frame_length > MAX_FRAME_SAMPLES) return enif_make_badarg(env);
  if (channels < 1 || channels > MAX_CHANNELS) return enif_make_badarg(env);
  if (sample_size != 16 && sample_size != 24) return enif_make_badarg(env);

  decoder *d = enif_alloc_resource(DECODER, sizeof(decoder));
  d->alac = NULL;
  d->out = NULL;

  d->alac = alac_create(sample_size, channels);
  d->out = enif_alloc(MAX_FRAME_BYTES);

  if (!d->alac || !d->out) {
    enif_release_resource(d);
    return enif_make_badarg(env);
  }

  /* The decoder skips 24 bytes of wrapping, so the config is handed to it behind
     that much padding rather than asking every caller to carry it. */
  unsigned char cookie[COOKIE_PREFIX + COOKIE_CONFIG];
  memset(cookie, 0, COOKIE_PREFIX);
  memcpy(cookie + COOKIE_PREFIX, config.data, COOKIE_CONFIG);

  /* alac_set_info allocates the working buffers itself, so calling
     alac_allocate_buffers here as well would leak the first set of them. */
  alac_set_info(d->alac, (char *)cookie);

  ERL_NIF_TERM term = enif_make_resource(env, d);
  enif_release_resource(d);

  return enif_make_tuple2(env, enif_make_atom(env, "ok"), term);
}

/* decode(decoder, frame) -> {:ok, samples} */
static ERL_NIF_TERM decode(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  decoder *d;
  ErlNifBinary frame;

  if (!enif_get_resource(env, argv[0], DECODER, (void **)&d) ||
      !enif_inspect_binary(env, argv[1], &frame)) {
    return enif_make_badarg(env);
  }

  int size = MAX_FRAME_BYTES;

  alac_decode_frame(d->alac, frame.data, (int)frame.size, d->out, &size);

  if (size < 0 || size > MAX_FRAME_BYTES) return enif_make_badarg(env);

  ERL_NIF_TERM samples;
  unsigned char *into = enif_make_new_binary(env, size, &samples);
  memcpy(into, d->out, size);

  return enif_make_tuple2(env, enif_make_atom(env, "ok"), samples);
}

static ErlNifFunc functions[] = {
  {"start", 3, start, 0},
  {"decode", 2, decode, ERL_NIF_DIRTY_JOB_CPU_BOUND}
};

ERL_NIF_INIT(Elixir.PiFi.AirPlay.Alac.Native.Nif, functions, load, NULL, NULL, NULL)
