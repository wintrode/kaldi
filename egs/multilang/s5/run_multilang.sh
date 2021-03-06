#!/bin/bash
# Copyright (c) 2015, Johns Hopkins University ( Yenda Trmal <jtrmal@gmail.com> )
# License: Apache 2.0

# Begin configuration section.
system=nnet_ms_p_sp
use_gpu=true
train_stage=-99
stage=-99
# End configuration section
. ./utils/parse_options.sh

set -e -o pipefail
set -o nounset                              # Treat unset variables as an error

. ./cmd.sh
. ./path.sh
num_jobs=50


if $use_gpu; then
  if ! cuda-compiled; then
    echo Main script not on CUDA machine
  fi
  parallel_opts="  --gpu 1"
  combine_num_threads=24
  combine_parallel_opts=" --gpu 0 --num-threads 24 "
  num_threads=1
  minibatch_size=512
  # the _a is in case I want to change the parameters.
else
  # Use 4 nnet jobs just like run_4d_gpu.sh so the results should be
  # almost the same, but this may be a little bit slow.
  num_threads=24
  minibatch_size=128
  parallel_opts="--num-threads $num_threads"
  combine_parallel_opts="--num-threads 16"
fi

if [ $stage -le 0 ]; then
  steps/nnet2/train_multilang2.sh --parallel-opts "$parallel_opts" \
    --num-threads $num_threads --minibatch-size $minibatch_size \
    --combine-parallel-opts "$combine_parallel_opts" \
    --combine-num-threads $combine_num_threads --unshare-layers "0:1:2"\
    --num-epochs 6 --mix-up "0 0 0" --num-jobs-nnet "6 4 4"\
    --cmd "$train_cmd --config conf/queue.conf"  --stage $train_stage \
    --train-cmd "$cuda_cmd --config conf/queue.conf" \
    ./exp/tri3_ali_sp  ./exp/nnet2_online/nnet_ms_p_sp/egs\
    ../exp_A/exp/tri3_ali_sp ../exp_A/exp/nnet2_online/nnet_ms_p_sp/egs\
    ../exp_B/exp/tri3_ali_sp ../exp_B/exp/nnet2_online/nnet_ms_p_sp/egs\
     exp/nnet2_online/$system/final.mdl  \
     exp_multilang/$system
fi

if [ $stage -le 1 ] ; then

  if [ ! -d data/langp_test_A ]; then
	cp -r ../exp_A/data/langp_test data/langp_test_A
  fi

  if [ ! -d data/langp_test_B ]; then
	cp -r ../exp_B/data/langp_test data/langp_test_B
  fi

  echo Making joint corpus graph
  utils/mkgraph.sh  data/langp_test/ exp_multilang/$system/0 \
    exp_multilang/$system/0/graphp

  echo Making corpus A graph
  utils/mkgraph.sh  data/langp_test_A/ exp_multilang/$system/1 \
    exp_multilang/$system/1/graphp

  echo Making corpus B graph
  utils/mkgraph.sh  data/langp_test_B/ exp_multilang/$system/2 \
    exp_multilang/$system/2/graphp
fi

if [ $stage -le 2 ]; then
  mkdir -p exp_multilang/${system}_online/0/
  steps/online/nnet2/prepare_online_decoding.sh --mfcc-config conf/mfcc_hires.conf\
    data/langp_test exp/nnet2_online/extractor \
    exp_multilang/$system/0/ \
    exp_multilang/${system}_online/0/

  mkdir -p exp_multilang/${system}_online/1/
  steps/online/nnet2/prepare_online_decoding.sh --mfcc-config conf/mfcc_hires.conf\
    data/langp_test_A/ ../exp_A/exp/nnet2_online/extractor \
    exp_multilang/${system}/1/ \
    exp_multilang/${system}_online/1/

  mkdir -p exp_multilang/${system}_online/2/
  steps/online/nnet2/prepare_online_decoding.sh --mfcc-config conf/mfcc_hires.conf\
    data/langp_test_B/ ../exp_B/exp/nnet2_online/extractor \
    exp_multilang/${system}/2/ \
    exp_multilang/${system}_online/2/

fi

if [ $stage -le 3 ]; then
  for am in 0 1 2 ; do
    for decode_set in dev10h fsp_eval ; do
      decode=exp_multilang/${system}_online/$am/decode_${decode_set}_utt_offline_prob
      mkdir -p $decode;
      if [ $decode_set == "dev10h" ]; then
		num_jobs=20
      else
		num_jobs=50
      fi
      steps/online/nnet2/decode.sh --config conf/decode.config\
        --cmd "$decode_cmd" --nj $num_jobs --per-utt true --online false \
        exp_multilang/${system}/$am/graphp \
        data/${decode_set}_hires  $decode | tee $decode/decode.log 
    done
  done
fi





