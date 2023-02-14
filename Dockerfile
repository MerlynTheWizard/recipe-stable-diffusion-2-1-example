ARG FROM_IMAGE="gadicc/diffusers-api-base:python3.9-pytorch1.12.1-cuda11.6-xformers"
# You only need the -banana variant if you need banana's optimization
# i.e. not relevant if you're using RUNTIME_DOWNLOADS
# ARG FROM_IMAGE="gadicc/python3.9-pytorch1.12.1-cuda11.6-xformers-banana"
FROM ${FROM_IMAGE} as base
ENV FROM_IMAGE=${FROM_IMAGE}

# Note, docker uses HTTP_PROXY and HTTPS_PROXY (uppercase)
# We purposefully want those managed independently, as we want docker
# to manage its own cache.  This is just for pip, models, etc.
ARG http_proxy
ARG https_proxy
RUN if [ -n "$http_proxy" ] ; then \
    echo quit \
    | openssl s_client -proxy $(echo ${https_proxy} | cut -b 8-) -servername google.com -connect google.com:443 -showcerts \
    | sed 'H;1h;$!d;x; s/^.*\(-----BEGIN CERTIFICATE-----.*-----END CERTIFICATE-----\)\n---\nServer certificate.*$/\1/' \
    > /usr/local/share/ca-certificates/squid-self-signed.crt ; \
    update-ca-certificates ; \
  fi
ARG REQUESTS_CA_BUNDLE=${http_proxy:+/usr/local/share/ca-certificates/squid-self-signed.crt}

ARG DEBIAN_FRONTEND=noninteractive

FROM base AS patchmatch
ARG USE_PATCHMATCH=0
WORKDIR /tmp
COPY scripts/patchmatch-setup.sh .
RUN sh patchmatch-setup.sh

FROM base as output
RUN mkdir /api
WORKDIR /api

# we use latest pip in base image
# RUN pip3 install --upgrade pip

ADD requirements.txt requirements.txt
RUN pip install -r requirements.txt

# [dreambooth] check the low-precision guard before preparing model (#2102)
RUN git clone https://github.com/huggingface/diffusers && cd diffusers && git checkout 946d1cb200a875f694818be37c9c9f7547e9db45
WORKDIR /api
RUN pip install -e diffusers

# Set to true to NOT download model at build time, rather at init / usage.
ARG RUNTIME_DOWNLOADS=0
ENV RUNTIME_DOWNLOADS=${RUNTIME_DOWNLOADS}

# TODO, to dda-bananana
# ARG PIPELINE="StableDiffusionInpaintPipeline"
ARG PIPELINE="ALL"
ENV PIPELINE=${PIPELINE}

# Deps for RUNNING (not building) earlier options
ARG USE_PATCHMATCH=0
RUN if [ "$USE_PATCHMATCH" = "1" ] ; then apt-get install -yqq python3-opencv ; fi
COPY --from=patchmatch /tmp/PyPatchMatch PyPatchMatch

# TODO, just include by default, and handle all deps in OUR requirements.txt
ARG USE_DREAMBOOTH=1
ENV USE_DREAMBOOTH=${USE_DREAMBOOTH}

RUN if [ "$USE_DREAMBOOTH" = "1" ] ; then \
    # By specifying the same torch version as conda, it won't download again.
    # Without this, it will upgrade torch, break xformers, make bigger image.
    pip install -r diffusers/examples/dreambooth/requirements.txt bitsandbytes torch==1.12.1 ; \
  fi
RUN if [ "$USE_DREAMBOOTH" = "1" ] ; then apt-get install git-lfs ; fi

COPY api/ .
EXPOSE 50150

# HF Model id, precision, etc.
ARG MODEL_ID="stabilityai/stable-diffusion-2-1-base"
ENV MODEL_ID=${MODEL_ID}
ARG HF_MODEL_ID=""
ENV HF_MODEL_ID=${HF_MODEL_ID}
ARG MODEL_PRECISION="fp16"
ENV MODEL_PRECISION=${MODEL_PRECISION}
ARG MODEL_REVISION="fp16"
ENV MODEL_REVISION=${MODEL_REVISION}

# To use a .ckpt file, put the details here.
ARG CHECKPOINT_URL=""
ENV CHECKPOINT_URL=${CHECKPOINT_URL}
ARG CHECKPOINT_CONFIG_URL=""
ENV CHECKPOINT_CONFIG_URL=${CHECKPOINT_CONFIG_URL}

ARG PIPELINE="ALL"
ENV PIPELINE=${PIPELINE}

# Download the model
ENV RUNTIME_DOWNLOADS=0
RUN python3 download.py

RUN apt update
RUN apt install -y curl
RUN curl -s https://ngrok-agent.s3.amazonaws.com/ngrok.asc | tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null && echo "deb https://ngrok-agent.s3.amazonaws.com buster main" | tee /etc/apt/sources.list.d/ngrok.list && apt update && apt install ngrok
RUN ngrok config add-authtoken YOUR_TOKEN_HERE
ARG NGROK_TUNNEL_EDGE="YOUR_EDGE_HERE"
ENV NGROK_TUNNEL_EDGE=${NGROK_TUNNEL_EDGE}

ARG SAFETENSORS_FAST_GPU=1
ENV SAFETENSORS_FAST_GPU=${SAFETENSORS_FAST_GPU}

CMD bash start.sh

