#!/bin/bash
set -e

function init_variables() {
    print_help_if_needed $@
    script_dir=$(dirname $(realpath "$0"))
    
    # Get current directory
    readonly CUR_DIR=$(pwd)
    
    # Update paths with CUR_DIR
    readonly RESOURCES_DIR="$CUR_DIR/resources"
    readonly CROPPER_SO="$RESOURCES_DIR/libvms_croppers.so"

    readonly TEMP_DIR="$CUR_DIR/tmp"
    readonly DETECTION_JSON_FILE="$TEMP_DIR/face_detection_output.json"
    readonly RECOGNITION_JSON_FILE="$TEMP_DIR/face_recognition_output.json"

    # Face Alignment
    readonly FACE_ALIGN_SO="$RESOURCES_DIR/libvms_face_align.so"

    # Face Recognition
    readonly RECOGNITION_POST_SO="$RESOURCES_DIR/libface_recognition_post_h8l.so"
    readonly RECOGNITION_HEF_PATH="$RESOURCES_DIR/arcface_mobilefacenet.hef"

    # Face Detection and Landmarking
    readonly DEFAULT_HEF_PATH="$RESOURCES_DIR/scrfd_10g.hef"
    readonly POSTPROCESS_SO="$RESOURCES_DIR/libscrfd_post_h8l.so"
    readonly FACE_JSON_CONFIG_PATH="$RESOURCES_DIR/configs/scrfd.json"
    readonly FUNCTION_NAME="scrfd_10g"

    detection_network="scrfd_10g"

    detection_hef=$DEFAULT_HEF_PATH
    detection_post=$FUNCTION_NAME
    recognition_hef=$RECOGNITION_HEF_PATH
    recognition_post="arcface_rgb"

    video_format="RGB"

    # Set default input source to libcamera
    input_source="libcamera"
    video_sink_element=$([ "$XV_SUPPORTED" = "true" ] && echo "xvimagesink" || echo "ximagesink")
    # Set default to show fps
    # additional_parameters="-v 2>&1 | grep hailo_display"
    print_gst_launch_only=false
    vdevice_key=1
    local_gallery_file="$RESOURCES_DIR/gallery/face_recognition_local_gallery_rgba.json"
}

function print_usage() {
    echo "Face recognition - pipeline usage:"
    echo ""
    echo "Options:"
    echo "  --help                          Show this help"
    echo "  --show-fps                      Printing fps"
    echo "  -i INPUT --input INPUT          Set the input source (default $input_source)"
    echo "  --network NETWORK               Set network to use. choose from [scrfd_10g, scrfd_2_5g], default is scrfd_10g"
    echo "  --format FORMAT                 Choose video format from [RGB], default is RGB"
    echo "  --print-gst-launch              Print the ready gst-launch command without running it"
    exit 0
}

function print_help_if_needed() {
    while test $# -gt 0; do
        if [ "$1" = "--help" ] || [ "$1" == "-h" ]; then
            print_usage
        fi
        shift
    done
}

function parse_args() {
    while test $# -gt 0; do
        if [ "$1" = "--help" ] || [ "$1" == "-h" ]; then
            print_usage
            exit 0
        elif [ "$1" = "--print-gst-launch" ]; then
            print_gst_launch_only=true
        elif [ "$1" = "--show-fps" ]; then
            echo "Printing fps"
            additional_parameters="-v 2>&1 | grep hailo_display"
        elif [ "$1" = "--input" ] || [ "$1" == "-i" ]; then
            input_source="$2"
            shift
        elif [ $1 == "--network" ]; then
            if [ $2 == "scrfd_2_5g" ]; then
                detection_network="scrfd_2_5g"
                hef_path="$RESOURCES_DIR/scrfd_2_5g.hef"
                detection_post="scrfd_2_5g"
            elif [ $2 != "scrfd_10g" ]; then
                echo "Received invalid network: $2. See expected arguments below:"
                print_usage
                exit 1
            fi
            shift
        elif [ $1 == "--format" ]; then
            if [ $2 == "NV12" ]; then
                video_format="NV12"
                local_gallery_file="$RESOURCES_DIR/gallery/face_recognition_local_gallery_nv12.json"
            elif [ $2 == "RGB" ]; then
                video_format="RGB"
            else
                echo "Received invalid format: $2. See expected arguments below:"
                print_usage
                exit 1
            fi
            shift
        else
            echo "Received invalid argument: $1. See expected arguments below:"
            print_usage
            exit 1
        fi
        shift
    done
}

function set_networks() {
    # Face Recognition model path
    # (We do NOT set source_element here!)
    echo "Loading Face Recognition model: $recognition_hef"

    # Face Detection model
    if [ "$video_format" == "RGB" ] && [ "$detection_network" == "scrfd_10g" ]; then
        hef_path="$RESOURCES_DIR/scrfd_10g.hef"
        echo "Loading Face Detection model: $hef_path"
        recognition_post="arcface_rgb"
    elif [ "$video_format" == "RGB" ] && [ "$detection_network" == "scrfd_2_5g" ]; then
        hef_path="$RESOURCES_DIR/scrfd_2_5g.hef"
        echo "Loading Face Detection model: $hef_path"
        recognition_post="arcface_rgb"
    else
        echo "ERROR: Either unsupported format or unsupported detection network."
        exit 1
    fi
}

function main() {
    init_variables $@
    parse_args $@
    set_networks $@

    # Decide which GStreamer source element to use
    if [[ $input_source =~ "/dev/video" ]]; then
        # v4l2 camera
        source_element="v4l2src device=$input_source name=src_0 ! \
                        video/x-raw,format=YUY2,width=1920,height=1080,framerate=30/1 ! \
                        queue max-size-buffers=50 max-size-bytes=0 max-size-time=0"
    elif [[ "$input_source" == "libcamera" ]]; then
        # PiCamera2 with libcamera - Capture at 1080p and scale to 640x480
        source_element="libcamerasrc name=src_0 ! \
                        video/x-raw,format=NV12,width=1920,height=1080,framerate=15/1 ! \
                        queue max-size-buffers=50 max-size-bytes=0 max-size-time=0 ! \
                        videoconvert ! \
                        video/x-raw,format=YUY2 ! \
                        videoscale method=1 add-borders=false ! \
                        video/x-raw,width=640,height=360,pixel-aspect-ratio=1/1"
    else
        # default: treat as file source
        source_element="filesrc location=$input_source name=src_0 ! decodebin"
    fi

    RECOGNITION_PIPELINE="hailocropper so-path=$CROPPER_SO function-name=face_recognition internal-offset=true name=cropper2 \
        hailoaggregator name=agg2 \
        cropper2. ! \
            queue name=bypess2_q leaky=downstream max-size-buffers=50 max-size-bytes=0 max-size-time=0 ! \
        agg2. \
        cropper2. ! \
            queue name=pre_face_align_q leaky=downstream max-size-buffers=50 max-size-bytes=0 max-size-time=0 ! \
            hailofilter so-path=$FACE_ALIGN_SO name=face_align_hailofilter use-gst-buffer=true qos=true ! \
            queue name=detector_pos_face_align_q leaky=downstream max-size-buffers=50 max-size-bytes=0 max-size-time=0 ! \
            hailonet hef-path=$recognition_hef scheduling-algorithm=1 vdevice-key=$vdevice_key ! \
            queue name=recognition_post_q leaky=downstream max-size-buffers=50 max-size-bytes=0 max-size-time=0 ! \
            hailofilter function-name=$recognition_post so-path=$RECOGNITION_POST_SO name=face_recognition_hailofilter qos=true ! \
            hailoexportzmq address=\"tcp://*:5555\" ! \
            queue name=recognition_pre_agg_q leaky=downstream max-size-buffers=50 max-size-bytes=0 max-size-time=0 ! \
        agg2. \
        agg2. "

    FACE_DETECTION_PIPELINE="hailonet hef-path=$hef_path scheduling-algorithm=1 vdevice-key=$vdevice_key ! \
        queue name=detector_post_q leaky=downstream max-size-buffers=50 max-size-bytes=0 max-size-time=0 ! \
        hailofilter so-path=$POSTPROCESS_SO name=face_detection_hailofilter qos=true config-path=$FACE_JSON_CONFIG_PATH function_name=$detection_post ! \
        queue name=export_q leaky=downstream max-size-buffers=50 max-size-bytes=0 max-size-time=0"

    FACE_TRACKER="hailotracker name=hailo_face_tracker class-id=-1 kalman-dist-thr=0.7 iou-thr=0.8 init-iou-thr=0.9 \
                    keep-new-frames=2 keep-tracked-frames=6 keep-lost-frames=8 keep-past-metadata=true debug=false qos=true"

    DETECTOR_PIPELINE="tee name=t hailomuxer name=hmux \
        t. ! \
            queue name=detector_bypass_q leaky=downstream max-size-buffers=50 max-size-bytes=0 max-size-time=0 ! \
        hmux. \
        t. ! \
            videoscale name=face_videoscale method=0 n-threads=2 add-borders=false qos=true ! \
            video/x-raw, pixel-aspect-ratio=1/1 ! \
            queue name=pre_face_detector_infer_q leaky=downstream max-size-buffers=50 max-size-bytes=0 max-size-time=0 ! \
            $FACE_DETECTION_PIPELINE ! \
            queue leaky=downstream max-size-buffers=50 max-size-bytes=0 max-size-time=0 ! \
        hmux. \
        hmux. "

    pipeline="gst-launch-1.0 \
        $source_element ! \
        queue name=hailo_pre_convert_0 leaky=downstream max-size-buffers=50 max-size-bytes=0 max-size-time=0 ! \
        videoconvert n-threads=2 qos=true ! \
        queue name=pre_detector_q leaky=downstream max-size-buffers=50 max-size-bytes=0 max-size-time=0 ! \
        $DETECTOR_PIPELINE ! \
        queue name=pre_tracker_q leaky=downstream max-size-buffers=50 max-size-bytes=0 max-size-time=0 ! \
        $FACE_TRACKER ! \
        queue name=hailo_post_tracker_q leaky=downstream max-size-buffers=50 max-size-bytes=0 max-size-time=0 ! \
        $RECOGNITION_PIPELINE ! \
        queue name=hailo_pre_gallery_q leaky=downstream max-size-buffers=50 max-size-bytes=0 max-size-time=0 ! \
        hailogallery gallery-file-path=$local_gallery_file \
        load-local-gallery=false similarity-thr=.8 gallery-queue-size=20 class-id=-1 ! \
        queue name=hailo_pre_draw2 leaky=downstream max-size-buffers=50 max-size-bytes=0 max-size-time=0 ! \
        hailooverlay name=hailo_overlay qos=true show-confidence=true local-gallery=true line-thickness=5 font-thickness=2 landmark-point-radius=8 ! \
        queue name=hailo_post_draw leaky=downstream max-size-buffers=50 max-size-bytes=0 max-size-time=0 ! \
        videoconvert n-threads=4 qos=true name=display_videoconvert qos=true ! \
        queue name=hailo_display_q_0 leaky=downstream max-size-buffers=50 max-size-bytes=0 max-size-time=0 ! \
        fpsdisplaysink video-sink=$video_sink_element name=hailo_display sync=false text-overlay=false \
        ${additional_parameters}"

    echo "${pipeline}"
    if [ "$print_gst_launch_only" = true ]; then
        exit 0
    fi

    echo "Running Pipeline..."
    eval "${pipeline}"
}

main $@
