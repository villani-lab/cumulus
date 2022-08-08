version 1.0

workflow spaceranger_count {
    input {
        # Sample ID
        String sample_id
        # A comma-separated list of input FASTQs directories (gs urls)
        String input_fastqs_directories
        # spaceranger output directory, gs url
        String output_directory

        # Referece index TSV
        File acronym_file

        # A reference genome name or a URL to a tar.gz file
        String genome

        # Probe set for FFPE samples, choosing from human_probe_v1, human_probe_v2, mouse_probe_v1 or a user-provided csv file. Default to '', not FFPE
        String probe_set = ""
        # Whether to filter the probe set using the "included" column of the probe set CSV. Default: true
        Boolean filter_probes = true

        # Brightfield tissue H&E image in .jpg or .tiff format.
        File? image
        # Multi-channel, dark-background fluorescence image as either a single, multi-layer .tiff file, multiple .tiff or .jpg files, or a pre-combined color .tiff or .jpg file.
        Array[File]? darkimage
        # A semi-colon ';' separated string denoting all dark images. This option is equivalent to darkimage and should only be used by spaceranger_workflow
        String? darkimagestr
        # A color composite of one or more fluorescence image channels saved as a single-page, single-file color .tiff or .jpg.
        File? colorizedimage
        # Brightfield image generated by the CytAssist instrument.
        File? cytaimage

        # Index of DAPI channel (1-indexed) of fluorescence image, only used in the CytaAssist case, with dark background image.
        Int? dapi_index

        # Visium slide serial number.
        String? slide
        # Visium capture area identifier. Options for Visium are A1, B1, C1, D1.
        String? area
        # Slide layout file indicating capture spot and fiducial spot positions.
        File? slidefile
        # Use this option if the slide serial number and area identifier have been lost. Choose from visium-1, visium-2 and visium-2-large.
        String? unknown_slide

        # Use with automatic image alignment to specify that images may not be in canonical orientation with the hourglass in the top left corner of the image. The automatic fiducial alignment will attempt to align any rotation or mirroring of the image.
        Boolean reorient_images = true
        # Alignment file produced by the manual Loupe alignment step. A --image must be supplied in this case.
        File? loupe_alignment

        # Target panel CSV for targeted gene expression analysis
        File? target_panel

        # If generate bam outputs
        Boolean no_bam = false
        # Perform secondary analysis of the gene-barcode matrix (dimensionality reduction, clustering and visualization). Default: false
        Boolean secondary = false

        # Hard trim the input Read 1 to this length before analysis
        Int? r1_length
        # Hard trim the input Read 2 to this length before analysis
        Int? r2_length

        # spaceranger version
        String spaceranger_version
        # Which docker registry to use: cumulusprod (default) or quay.io/cumulus
        String docker_registry

        # Google cloud zones, default to "us-central1-b", which is consistent with CromWell's genomics.default-zones attribute
        String zones = "us-central1-b"
        # Number of cpus per spaceranger job
        Int num_cpu = 32
        # Memory string, e.g. 120G
        String memory = "120G"
        # Disk space in GB
        Int disk_space = 500
        # Number of preemptible tries
        Int preemptible = 2
        # Number of maximum retries when running on AWS
        Int awsMaxRetries = 5
        # Arn string of AWS queue
        String awsQueueArn = ""
        # Backend
        String backend
    }

    Map[String, String] acronym2url = read_map(acronym_file)
    File null_file = acronym2url["null_file"]

    # If reference is a url
    Boolean is_url = sub(genome, "^.+\\.(tgz|gz)$", "URL") == "URL"
    # Replace name with actual url
    File genome_file = (if is_url then genome else acronym2url[genome])

    # If replace probset with its corresponding URL for CSV file
    File probe_file = (if probe_set == "" then null_file else (if sub(probe_set, "^.+\\.csv$", "CSV") != "CSV" then acronym2url[probe_set] else probe_set))


    call run_spaceranger_count {
        input:
            sample_id = sample_id,
            input_fastqs_directories = input_fastqs_directories,
            output_directory = output_directory,
            genome_file = genome_file,
            probe_file = probe_file,
            probe_set = probe_set,
            filter_probes = filter_probes,
            image = image,
            darkimage = darkimage,
            darkimagestr = darkimagestr,
            colorizedimage = colorizedimage,
            cytaimage = cytaimage,
            dapi_index = dapi_index,
            slide = slide,
            area = area,
            slidefile = slidefile,
            unknown_slide = unknown_slide,
            reorient_images = reorient_images,
            loupe_alignment = loupe_alignment,
            target_panel = target_panel,
            no_bam = no_bam,
            secondary = secondary,
            r1_length = r1_length,
            r2_length = r2_length,
            spaceranger_version = spaceranger_version,
            docker_registry = docker_registry,
            zones = zones,
            num_cpu = num_cpu,
            memory = memory,
            disk_space = disk_space,
            preemptible = preemptible,
            awsMaxRetries = awsMaxRetries,
            awsQueueArn = awsQueueArn,
            backend = backend
    }

    output {
        String output_count_directory = run_spaceranger_count.output_count_directory
        String output_metrics_summary = run_spaceranger_count.output_metrics_summary
        String output_web_summary = run_spaceranger_count.output_web_summary
        File monitoringLog = run_spaceranger_count.monitoringLog
    }
}

task run_spaceranger_count {
    input {
        String sample_id
        String input_fastqs_directories
        String output_directory
        File genome_file
        File probe_file
        String probe_set
        Boolean filter_probes
        File? image
        Array[File]? darkimage
        String? darkimagestr
        File? colorizedimage
        File? cytaimage
        Int? dapi_index
        String? slide
        String? area
        File? slidefile
        String? unknown_slide
        Boolean reorient_images
        File? loupe_alignment
        File? target_panel
        Boolean no_bam
        Boolean secondary
        Int? r1_length
        Int? r2_length
        String spaceranger_version
        String docker_registry
        String zones
        Int num_cpu
        String memory
        Int disk_space
        Int preemptible
        Int awsMaxRetries
        String awsQueueArn
        String backend
    }

    command {
        set -e
        export TMPDIR=/tmp
        export BACKEND=~{backend}
        monitor_script.sh > monitoring.log &
        mkdir -p genome_dir
        tar xf ~{genome_file} -C genome_dir --strip-components 1

        python <<CODE
        import os
        import re
        import sys
        from subprocess import check_call, CalledProcessError, DEVNULL, STDOUT
        from packaging import version

        fastqs = []
        for i, directory in enumerate('~{input_fastqs_directories}'.split(',')):
            directory = re.sub('/+$', '', directory) # remove trailing slashes
            target = '~{sample_id}' + "_" + str(i)
            try:
                call_args = ['strato', 'exists', '--backend', '~{backend}', directory + '/~{sample_id}/']
                print(' '.join(call_args))
                check_call(call_args, stdout=DEVNULL, stderr=STDOUT)
                call_args = ['strato', 'sync', '--backend', '~{backend}', '-m', directory + '/~{sample_id}', target]
                print(' '.join(call_args))
                check_call(call_args)
            except CalledProcessError:
                if not os.path.exists(target):
                    os.mkdir(target)
                call_args = ['strato', 'cp', '--backend', '~{backend}', '-m', directory + '/~{sample_id}' + '_S*_L*_*_001.fastq.gz' , target]
                check_call(call_args)
            fastqs.append('~{sample_id}_' + str(i))

        call_args = ['spaceranger', 'count', '--id=results', '--transcriptome=genome_dir', '--fastqs=' + ','.join(fastqs), '--sample=~{sample_id}', '--jobmode=local']

        def not_null(input_file):
            return (input_file != '') and (os.path.basename(input_file) != 'null')

        def get_darkimages(darkimage, darkimagestr):
            darkimages = []
            if darkimage != '':
                darkimages = darkimage.split(';')
            elif darkimagestr != '':
                for i, file in enumerate(darkimagestr.split(';')):
                    local_file = '_' + str(i) + '_' + os.path.basename(file)
                    call_args = ['strato', 'cp', '--backend', '~{backend}', file, local_file]
                    print(' '.join(call_args))
                    check_call(call_args)
                    darkimages.append(local_file)
            return darkimages

        has_cyta = not_null('~{cytaimage}')
        if not_null('~{probe_file}'):
            call_args.extend(['--probe-set=~{probe_file}', '--filter-probes=~{filter_probes}'])
            if has_cyta and probe_set == "human_probe_v1":
                print("CytAssit enabled FFPE is only compatible with human probe set v2!", file = sys.stderr)
                sys.exit(1)
            if not has_cyta and probe_set == "human_probe_v2":
                print("Non-CytAssist enabled FFPE is only compatible with human probe set v1!", file = sys.stderr)
                sys.exit(1)

        if not_null('~{target_panel}'):
            call_args.append('--target-panel=~{target_panel}')

        has_image = not_null('~{image}')
        darkimages = get_darkimages('~{sep=";" darkimage}', '~{darkimagestr}')
        has_cimage = not_null('~{colorizedimage}')
        
        ntrue = has_image + (len(darkimages) > 0) + has_cimage
        if ntrue == 0 and not has_cyta:
            print("Please set one of the following arguments: image, darkimage, colorizedimage or cytaimage!", file = sys.stderr)
            sys.exit(1)
        elif ntrue > 1:
            print("Please only set one of the following arguments: image, darkimage or colorizedimage!", file = sys.stderr)
            sys.exit(1)

        if has_cyta:
            call_args.append('--cytaimage=~{cytaimage}')

        if has_image:
            call_args.append('--image=~{image}')
        elif len(darkimages) > 0:
            call_args.extend(['--darkimage=' + x for x in darkimages])
            if has_cyta and '~{dapi_index} != '':
                call_args.append('--dapi-index=~{dapi_index}')
        else:
            call_args.append('--colorizedimage=~{colorizedimage}')

        if '~{area}' == '' and '~{slide}' == '':
            if '~{unknown_slide}' == '':
                print("Please provide an input for the 'unknown_slide' argument, choosing from 'visium-1', 'visium-2', and 'visium-2-large'!", file = sys.stderr)
                sys.exit(1)
            call_args.append('--unknown-slide=~{unknown_slide}')
        else:
            if '~{area}' == '':
                print("Please provide an input for the 'area' argument!", file = sys.stderr)
                sys.exit(1)
            if '~{slide}' == '':
                print("Please provide an input for the 'slide' argument!", file = sys.stderr)
                sys.exit(1)
            call_args.extend(['--area=~{area}', '--slide=~{slide}'])
            if not_null('~{slidefile}'):
                call_args.append('--slidefile=~{slidefile}')

        if not has_cyta:
            call_args.append('--reorient-images=~{reorient_images}')
        
        if not_null('~{loupe_alignment}'):
            call_args.append('--loupe_alignment=~{loupe_alignment}')

        if '~{no_bam}' == 'true':
            call_args.append('--no-bam')
        if '~{secondary}' != 'true':
            call_args.append('--nosecondary')

        if '~{r1_length}' != '':
            call_args.append('--r1-length=~{r1_length}')
        r2_length = '~{r2_length}'
        if r2_length == '' and not_null('~{probe_file}') and version.parse('~{spaceranger_version}') < version.parse('2.0.0'):
            r2_length = '50'
        if r2_length != '':
            call_args.append('--r2-length=' + r2_length)

        print(' '.join(call_args))
        check_call(call_args)
        CODE

        strato sync --backend ~{backend} -m results/outs "~{output_directory}/~{sample_id}"
    }

    output {
        String output_count_directory = "~{output_directory}/~{sample_id}"
        String output_metrics_summary = "~{output_directory}/~{sample_id}/metrics_summary.csv"
        String output_web_summary = "~{output_directory}/~{sample_id}/web_summary.html"
        File monitoringLog = "monitoring.log"
    }

    runtime {
        docker: "~{docker_registry}/spaceranger:~{spaceranger_version}"
        zones: zones
        memory: memory
        bootDiskSizeGb: 12
        disks: "local-disk ~{disk_space} HDD"
        cpu: num_cpu
        preemptible: preemptible
        maxRetries: if backend == "aws" then awsMaxRetries else 0
        queueArn: awsQueueArn
    }
}
