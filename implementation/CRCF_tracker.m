function results = CRCF_tracker(params)
cell_size = params.cell_size;
padding = params.padding;
lambda = params.lambda;
output_sigma_factor = params.output_sigma_factor;
features = params.features;
features_large = params.features_large;
    
learning_rate_cf = params.learning_rate_cf;
learning_rate_hist = params.learning_rate_hist;
learning_rate_scale = params.learning_rate_scale;

params = init_all_areas(params);
window_sz = params.window_sz;
norm_window_sz = params.norm_window_sz;
norm_resize_factor = params.norm_resize_factor;
norm_target_sz = params.norm_target_sz;
norm_likelihood_sz = params.norm_likelihood_sz;
norm_delta_sz = params.norm_delta_sz;
cf_response_sz = params.cf_response_sz;
window_sz_large = params.window_sz_large;
norm_window_sz_large = params.norm_window_sz_large;

s_frames = params.s_frames;
pos = floor(params.init_pos);
old_pos = pos;
target_sz = floor(params.target_sz);
num_frames = params.num_frames;

rect_position = zeros(num_frames, 4);

base_target_sz = target_sz;

output_sigma = sqrt(prod(norm_target_sz)) * output_sigma_factor / cell_size;
y = gaussian_response(cf_response_sz, output_sigma);
yf = fft2(y);

det_sz = floor(norm_window_sz_large / cell_size);
params.det_sz = det_sz;
rg           = circshift(-floor((det_sz(1)-1)/2):ceil((det_sz(1)-1)/2), [0 -floor((det_sz(1)-1)/2)]);
cg           = circshift(-floor((det_sz(2)-1)/2):ceil((det_sz(2)-1)/2), [0 -floor((det_sz(2)-1)/2)]);
[rs, cs]     = ndgrid( rg,cg);
y            = exp(-0.5 * (((rs.^2 + cs.^2) / output_sigma^2)));
yf_detector  = fft2(y); %   FFT of y.
params.small_filter_sz = floor(norm_target_sz / cell_size);

center =(1 + norm_delta_sz) / 2;

cos_window = hann(cf_response_sz(1))*hann(cf_response_sz(2))';
cos_window_large = hann(floor(norm_window_sz_large(1)/cell_size))*hann(floor(norm_window_sz_large(2)/cell_size))';
currentScaleFactor = 1.0;

refinement_iteration = 1;

channel_weights(1) = 0.3850; % Gray Feature
channel_weights(2:14) = 0.3150; % HOG13 Feature
channel_weights(15) = 0.3; %  CR Feature
%prior_weights = ones(15,1);
%prior_weights = prior_weights / sum(prior_weights);
channel_weights = reshape(channel_weights, 1,1,15);

if params.use_scale_filter
    scale_sigma_factor= params.scale_sigma_factor;
    nScales = params.number_of_scales;
    nScalesInterp = params.number_of_interp_scales;
    scale_model_factor = params.scale_model_factor;
    scale_step = params.scale_step;
    scale_model_max_area = params.scale_model_max_area;
    scale_lambda = params.scale_lambda;
    
    scale_sigma = nScalesInterp * scale_sigma_factor;
    
    scale_exp = (-floor((nScales-1)/2):ceil((nScales-1)/2)) * nScalesInterp/nScales;
    scale_exp_shift = circshift(scale_exp, [0 -floor((nScales-1)/2)]);
    
    interp_scale_exp = -floor((nScalesInterp-1)/2):ceil((nScalesInterp-1)/2);
    interp_scale_exp_shift = circshift(interp_scale_exp, [0 -floor((nScalesInterp-1)/2)]);
    
    scaleSizeFactors = scale_step .^ scale_exp;
    interpScaleFactors = scale_step .^ interp_scale_exp_shift;
    
    ys = exp(-0.5 * (scale_exp_shift.^2) /scale_sigma^2);
    ysf = single(fft(ys));
    scale_window = single(hann(size(ysf,2)))';
    
    %make sure the scale model is not to large, to save computation time
    if scale_model_factor^2 * prod(base_target_sz) > scale_model_max_area
        scale_model_factor = sqrt(scale_model_max_area/prod(base_target_sz));
    end
    
    %set the scale model size
    scale_model_sz = floor(base_target_sz * scale_model_factor);
    
    im = imread(s_frames{1});
    
    %force reasonable scale changes
    min_scale_factor = scale_step ^ ceil(log(max(5 ./ window_sz)) / log(scale_step));
    max_scale_factor = scale_step ^ floor(log(min([size(im,1) size(im,2)] ./ base_target_sz)) / log(scale_step));
end

if params.gaussian_merge_sample
    im = imread(s_frames{1});
    distance_matrix = inf(params.nSamples, 'single');
    hash_samples = false(64, params.nSamples);
    samples_patch = zeros(params.nSamples, norm_window_sz(1), norm_window_sz(2), size(im, 3), 'uint8');
    samples_patch_large = zeros(params.nSamples, norm_window_sz_large(1), norm_window_sz_large(2), size(im, 3), 'uint8');
    samples_feature_extracted = false(params.nSamples,1);
    samples = zeros(params.nSamples, floor(norm_window_sz(1)/cell_size), floor(norm_window_sz(2)/cell_size), 15, 'single');
    samples_large = zeros(params.nSamples, floor(norm_window_sz_large(1)/cell_size), floor(norm_window_sz_large(2)/cell_size), 13, 'single');
    samplesf = zeros(params.nSamples, floor(norm_window_sz(1)/cell_size), floor(norm_window_sz(2)/cell_size), 15, 'like', params.data_type_complex);
    samplesf_large = zeros(params.nSamples, floor(norm_window_sz_large(1)/cell_size), floor(norm_window_sz_large(2)/cell_size), 13, 'like', params.data_type_complex);
    params.minimum_sample_weight = params.learning_rate*(1-params.learning_rate)^(2*params.nSamples);
    prior_weights = zeros(params.nSamples,1);
    num_training_samples = 0;
end

time = 0;

reliability_cf_mean = 0;
reliability_color_mean = 0;
reliability_response_mean = 0;
unreliable_flag = false;
lt_resp_flag = false;

for frame = 1:num_frames
    im = imread(s_frames{frame});
    
    tic();
    if frame>1
        iter = 1;
        while iter<=refinement_iteration
            unreliable_flag = false;
            patch = get_subwindow(im, pos, norm_window_sz, window_sz);
            [xt, colour_map] = extract_features(patch, features);
            %likelihood_map = mexResize(colour_map, cf_response_sz);
            %if (sum(likelihood_map(:))/prod(cf_response_sz)<0.01), likelihood_map = 1; end    
            %cos_window = cos_window_org .* likelihood_map;
            xt = bsxfun(@times, xt, channel_weights);
            xt = bsxfun(@times, xt, cos_window); 
            %xt = bsxfun(@times, xt, channel_weights);
            xtf = fft2(xt);
            hf = bsxfun(@rdivide, hf_num, sum(hf_den, 3)+lambda);

            response_cf = real(ifft2(sum(hf .* xtf, 3)));
            reliability_cf = max(response_cf(:)) * squeeze(APCE(response_cf));

            reliability_cf_mean = (reliability_cf_mean * (frame - 2) + reliability_cf) / (frame - 1);

            ratio_cf = reliability_cf / reliability_cf_mean;

            colour_map = mexResize(colour_map, norm_likelihood_sz);
            response_color = getCenterLikelihood(colour_map, norm_target_sz);

            reliability_color = max(response_color(:)) * squeeze(APCE(response_color));

            reliability_color_mean = (reliability_color_mean * (frame - 2) + reliability_color) / (frame - 1);

            ratio_color = reliability_color / reliability_color_mean;

            %response_cf = sum(response_cf, 3);
            response_cf = crop_response(response_cf, floor_odd(norm_delta_sz / cell_size));
            response_cf = mexResize(response_cf, norm_delta_sz, 'auto');

            merge_factor = reliability_color / (reliability_cf + reliability_color);

            response = (1 - merge_factor) * response_cf + merge_factor * response_color;

            reliability_response = max(response(:)) * squeeze(APCE(response));

            reliability_response_mean = (reliability_response_mean * (frame - 2) + reliability_response) / (frame - 1);

            ratio_response = reliability_response / reliability_response_mean;

            %[ratio_cf, ratio_color, ratio_response] 

            if ratio_cf<0.6 && ratio_color<0.7 && ratio_response<0.6
                fprintf('%d, Unreliable Frame\n', frame);
                unreliable_flag = true;
            end

            if ~unreliable_flag
                [row, col] = find(response == max(response(:)), 1);
                old_pos = pos;
                pos = pos + ([row, col] - center) / norm_resize_factor;
            end

            iter = iter + 1;
        end
        
        if params.use_scale_filter
            if ~unreliable_flag
                %create a new feature projection matrix
                [xs_pca, xs_npca] = get_scale_subwindow(im,pos,base_target_sz,currentScaleFactor*scaleSizeFactors,scale_model_sz);

                xs = feature_projection_scale(xs_npca,xs_pca,scale_basis,scale_window);
                xsf = fft(xs,[],2);

                scale_responsef = sum(sf_num .* xsf, 1) ./ (sf_den + scale_lambda);

                interp_scale_response = ifft( resizeDFT(scale_responsef, nScalesInterp), 'symmetric');

                recovered_scale_index = find(interp_scale_response == max(interp_scale_response(:)), 1);

                %set the scale
                currentScaleFactor = currentScaleFactor * interpScaleFactors(recovered_scale_index);
                %adjust to make sure we are not to large or to small
                if currentScaleFactor < min_scale_factor
                    currentScaleFactor = min_scale_factor;
                elseif currentScaleFactor > max_scale_factor
                    currentScaleFactor = max_scale_factor;
                end
            end
        end

        target_sz = round(base_target_sz * currentScaleFactor);
        avg_dim = sum(target_sz)/2;
        window_sz = round(target_sz + padding*avg_dim);
        if(window_sz(2)>size(im,2)),  window_sz(2)=size(im,2)-1;    end
        if(window_sz(1)>size(im,1)),  window_sz(1)=size(im,1)-1;    end

        window_sz = window_sz - mod(window_sz - target_sz, 2);

        norm_resize_factor = sqrt(params.fixed_area/prod(window_sz));  
    end
    
    if ~unreliable_flag
        features{3} = update_histogram_model(im, pos, target_sz, learning_rate_hist, features{3});
    end
    patch = get_subwindow(im, pos, norm_window_sz, window_sz);
    patch_large = get_subwindow(im, pos, norm_window_sz_large, window_sz_large);
    if params.gaussian_merge_sample
        if ~unreliable_flag
            [merged_sample, new_sample, merged_sample_id, new_sample_id, merge_sample_id1, merge_sample_id2, merge_w1, merge_w2, merged_hashcode, new_hashcode, distance_matrix, prior_weights] = ...
                    update_sample_space_model(samples_patch, patch, distance_matrix, hash_samples, prior_weights, num_training_samples, params);

            if num_training_samples < params.nSamples
                num_training_samples = num_training_samples + 1;
            end

            if merged_sample_id > 0
                 samples_patch(merged_sample_id,:,:,:) = merged_sample;
                 samples_large_to_merge1 = samples_patch_large(merge_sample_id1,:,:,:);
                 if merge_sample_id2==-1
                     samples_large_to_merge2 = patch_large;
                 else
                     samples_large_to_merge2 = samples_patch_large(merge_sample_id2,:,:,:);
                 end
                 samples_patch_large(merged_sample_id,:,:,:) = merge_samples(samples_large_to_merge1,samples_large_to_merge2,merge_w1,merge_w2);
                 samples_feature_extracted(merged_sample_id) = false;
                 hash_samples(:, merged_sample_id) = merged_hashcode;
                 [temp, ~] = extract_features(merged_sample, features);
                 temp = bsxfun(@times, temp, channel_weights);  
                 temp = bsxfun(@times, temp, cos_window); 
                 samples(merged_sample_id,:,:,:) = temp;
                 samplesf(merged_sample_id,:,:,:) = fft2(temp);
            end
            if new_sample_id > 0
                 samples_patch(new_sample_id,:,:,:) = new_sample;
                 samples_patch_large(new_sample_id,:,:,:) = patch_large;
                 samples_feature_extracted(new_sample_id) = false;
                 hash_samples(:, new_sample_id) = new_hashcode;
                 [temp, ~] = extract_features(new_sample, features);
                 temp = bsxfun(@times, temp, channel_weights);  
                 temp = bsxfun(@times, temp, cos_window); 
                 samples(new_sample_id,:,:,:) = temp;
                 samplesf(new_sample_id,:,:,:) = fft2(temp);
            end
        else
            % Handle unreliable frame
            if num_training_samples < params.nSamples
                   % Extract features
                   feature_extracted = samples_feature_extracted(1:num_training_samples);
                   if any(~feature_extracted)
                       [~feature_extracted]'
                       disp('Learning from new samples')
                       extract_ind = find(~feature_extracted);
                       for k=1:numel(extract_ind)
                           cur_ind = extract_ind(k);
                           [temp,~] = extract_features(squeeze(samples_patch_large(cur_ind,:,:,:)), features_large);
                           temp = bsxfun(@times, temp, cos_window_large);
                           samples_large(cur_ind,:,:,:) = temp;
                           samplesf_large(cur_ind,:,:,:) = fft2(temp);
                           samples_feature_extracted(cur_ind) = true;
                       end
                       
                       g = detector_train(samplesf_large, yf_detector, num_training_samples, params, prior_weights);
                       disp('Long term detector learned')
                   end
            else
                   % Extract features
                   feature_extracted = samples_feature_extracted;
                   if any(~feature_extracted)
                       [~feature_extracted]'
                       disp('Learning from new samples')
                       extract_ind = find(~feature_extracted);
                       for k=1:numel(extract_ind)
                           cur_ind = extract_ind(k);
                           [temp,~] = extract_features(squeeze(samples_patch_large(cur_ind,:,:,:)), features_large);
                           temp = bsxfun(@times, temp, cos_window_large);
                           samples_large(cur_ind,:,:,:) = temp;
                           samplesf_large(cur_ind,:,:,:) = fft2(temp);
                           samples_feature_extracted(cur_ind) = true;
                       end
                       
                       g = detector_train(samplesf_large, yf_detector, num_training_samples, params, prior_weights);
                       disp('Long term detector learned')
                   end
            end
            
            img_sz = floor([size(im, 1), size(im, 2)] * norm_resize_factor);
            img_det = mexResize(im, img_sz, 'auto');
            img_det_xt = extract_features(img_det, features_large);
            img_det_xf = fft2(img_det_xt);
            img_det_sz = [size(img_det_xt,1), size(img_det_xt,2)];
            % Insert the center coefficients of g to det_filter
            det_filter = zeros(size(img_det_xt, 1), size(img_det_xt, 2), 13);
            [~,~,g_c] = get_subwindow_no_window(g, floor(params.det_sz/2) , params.small_filter_sz);
            sy = max(floor(size(det_filter, 1)/2) + (1:params.small_filter_sz(1)) - floor(params.small_filter_sz(1)/2),1);
            sx = max(floor(size(det_filter, 2)/2) + (1:params.small_filter_sz(2)) - floor(params.small_filter_sz(2)/2),1);
            det_filter(sy, sx,:) = g_c;
            det_filter_f = fft2(det_filter);
            response_det = ifft2(sum(conj(det_filter_f).*img_det_xf, 3), 'symmetric');
            reliability_det = max(response_det(:)) * squeeze(APCE(response_det));
            
            if params.debug
                if ~lt_resp_flag
                    lt_resp_handle = figure('Name','Detector Response');
                    lt_resp_flag = true;
                end
            end
            
            if true
                half_det_sz = [floor(size(img_det_xt,1)/2), floor(size(img_det_xt,2)/2)];
                ry = half_det_sz(1) + 1 + (-floor((params.small_filter_sz(1)-1)/2):ceil((params.small_filter_sz(1)-1)/2));
                rx = half_det_sz(2) + 1 + (-floor((params.small_filter_sz(2)-1)/2):ceil((params.small_filter_sz(2)-1)/2));

                min_res = min(response_det(:));

                response_det(ry,:) = min_res;
                response_det(:,rx) = min_res;
                
                if params.debug
                    figure(lt_resp_handle)
                    mesh(fftshift(response_det))
                    colorbar
                end

                center_pos = [floor(size(im,1)/2), floor(size(im,2)/2)];
                max(response_det(:))
                [row, col] = ind2sub(size(response_det), find(response_det == max(response_det(:)), 1));
                disp_row = mod(row - 1 + floor((img_det_sz(1)-1)/2), img_det_sz(1)) - floor((img_det_sz(1)-1)/2);
                disp_col = mod(col - 1 + floor((img_det_sz(2)-1)/2), img_det_sz(2)) - floor((img_det_sz(2)-1)/2);
                    
                old_pos = pos;
                det_pos = center_pos + floor([disp_row, disp_col]*cell_size/norm_resize_factor);
                
                patch = get_subwindow(im, det_pos, norm_window_sz, window_sz);
                [xt, colour_map] = extract_features(patch, features);
                xt = bsxfun(@times, xt, channel_weights);
                xt = bsxfun(@times, xt, cos_window); 
                xtf = fft2(xt);
                hf = bsxfun(@rdivide, hf_num, sum(hf_den, 3)+lambda);
            
                response_cf = real(ifft2(sum(hf .* xtf, 3)));
                reliability_cf = max(response_cf(:)) * squeeze(APCE(response_cf));
            
                ratio_cf_det = reliability_cf / reliability_cf_mean;

                colour_map = mexResize(colour_map, norm_likelihood_sz);
                response_color = getCenterLikelihood(colour_map, norm_target_sz);
            
                reliability_color = max(response_color(:)) * squeeze(APCE(response_color));
            
                ratio_color_det = reliability_color / reliability_color_mean;

                %response_cf = sum(response_cf, 3);
                response_cf = crop_response(response_cf, floor_odd(norm_delta_sz / cell_size));
                response_cf = mexResize(response_cf, norm_delta_sz, 'auto');
            
                merge_factor = reliability_color / (reliability_cf + reliability_color);
                response = (1 - merge_factor) * response_cf + merge_factor * response_color;
                reliability_response = max(response(:)) * squeeze(APCE(response));
                
                ratio_response_det = reliability_response / reliability_response_mean;
                
                if ratio_cf_det>ratio_cf && ratio_color_det>ratio_color && ratio_response_det>ratio_response
                	fprintf('%d, Recovered Frame\n', frame);
                    unreliable_flag = false;
                    [row, col] = find(response == max(response(:)), 1);
                    old_pos = det_pos;
                    pos = det_pos + ([row, col] - center) / norm_resize_factor;
                end
            end
        end
        
        if (frame==1||mod(frame, params.train_gap)==0)
            if num_training_samples < params.nSamples
                %model_xf = sum(bsxfun(@times, prior_weights(1:num_training_samples), samplesf(1:num_training_samples,:,:,:)), 1);
                %model_xf_den = sum(bsxfun(@times, prior_weights(1:num_training_samples), samplesf(1:num_training_samples,:,:,:).*conj(samplesf(1:num_training_samples,:,:,:))), 1);
                %model_xf = squeeze(model_xf);
                %model_xf_den = squeeze(model_xf_den);
                
                if params.form2
                    model_x = sum(bsxfun(@times, prior_weights(1:num_training_samples), samples(1:num_training_samples,:,:,:)), 1);
                    model_x = squeeze(model_x);
                    %model_x = bsxfun(@times, model_x, channel_weights);  
                    %model_x = bsxfun(@times, model_x, cos_window); 
                    model_xf = fft2(model_x);

                    hf_num = bsxfun(@times, yf, conj(model_xf));
                    hf_den = model_xf .* conj(model_xf);
                else
                    %samplesf = fft(fft(samples, [], 2), [], 3);
                    model_xf = sum(bsxfun(@times, prior_weights(1:num_training_samples), samplesf(1:num_training_samples,:,:,:)), 1);
                    model_xf_den = sum(bsxfun(@times, prior_weights(1:num_training_samples), samplesf(1:num_training_samples,:,:,:).*conj(samplesf(1:num_training_samples,:,:,:))), 1);
                    model_xf = squeeze(model_xf);
                    model_xf_den = squeeze(model_xf_den);
                    
                    hf_num = bsxfun(@times, yf, conj(model_xf));
                    hf_den = model_xf_den;
                end
            else
                %model_xf = sum(bsxfun(@times, prior_weights, samplesf), 1);
                %model_xf = squeeze(model_xf);
                %model_xf_den = sum(bsxfun(@times, prior_weights, samplesf.*conj(samplesf)), 1);
                %model_xf_den = squeeze(model_xf_den);              
                if params.form2
                    model_x = sum(bsxfun(@times, prior_weights, samples), 1);
                    model_x = squeeze(model_x);
                    %model_x = bsxfun(@times, model_x, channel_weights);  
                    %model_x = bsxfun(@times, model_x, cos_window); 
                    model_xf = fft2(model_x);
                    hf_num = bsxfun(@times, yf, conj(model_xf));
                    hf_den = model_xf .* conj(model_xf);
                else
                    %samplesf = fft(fft(samples, [], 2), [], 3);
                    model_xf = sum(bsxfun(@times, prior_weights, samplesf), 1);
                    model_xf = squeeze(model_xf);
                    model_xf_den = sum(bsxfun(@times, prior_weights, samplesf.*conj(samplesf)), 1);
                    model_xf_den = squeeze(model_xf_den);
                    
                    hf_num = bsxfun(@times, yf, conj(model_xf));
                    hf_den = model_xf_den;
                end
                
            end
        end
    else
        %new_hf_num = bsxfun(@times, yf, conj(xtf));
        
        if frame == 1
             model_xtf = xtf;
        else
             model_xtf = (1 - learning_rate_cf) * model_xtf + learning_rate_cf * xtf;
        end
        %new_hf_den = conj(xtf) .* xtf;
        %S_xx = sum(conj(model_xtf).*model_xtf, 3);
        %hf = 1/lambda*bsxfun(@times, yf, conj(model_xtf))-bsxfun(@times, (1/lambda^2*S_xx)./(1+1/lambda*S_xx).*yf, conj(model_xtf));
        new_hf_num = bsxfun(@times, yf, conj(xtf));
        new_hf_den = conj(xtf) .* xtf;

        if frame == 1
             hf_num = new_hf_num;
             hf_den = new_hf_den;
        else
             hf_num = (1 - learning_rate_cf) * hf_num + learning_rate_cf * new_hf_num;
             hf_den = (1 - learning_rate_cf) * hf_den + learning_rate_cf * new_hf_den;
        end
    end
    
    if params.use_scale_filter
        if ~unreliable_flag
            %create a new feature projection matrix
            [xs_pca, xs_npca] = get_scale_subwindow(im, pos, base_target_sz, currentScaleFactor*scaleSizeFactors, scale_model_sz);

            if frame == 1
                s_num = xs_pca;
            else
                s_num = (1 - learning_rate_scale) * s_num + learning_rate_scale * xs_pca;
            end

            bigY = s_num;
            bigY_den = xs_pca;

            [scale_basis, ~] = qr(bigY, 0);
            [scale_basis_den, ~] = qr(bigY_den, 0);
            scale_basis = scale_basis';

            %create the filter update coefficients
            sf_proj = fft(feature_projection_scale([],s_num,scale_basis,scale_window),[],2);
            sf_num = bsxfun(@times,ysf,conj(sf_proj));

            xs = feature_projection_scale(xs_npca,xs_pca,scale_basis_den',scale_window);
            xsf = fft(xs,[],2);
            new_sf_den = sum(xsf .* conj(xsf),1);

            if frame == 1
                sf_den = new_sf_den;
            else
                sf_den = (1 - learning_rate_scale) * sf_den + learning_rate_scale * new_sf_den;
            end;
        end
    end

    %save position and calculate FPS
    rect_position(frame,:) = [pos([2,1]) - floor(target_sz([2,1])/2), target_sz([2,1])];

    time = time + toc();
    
    if params.visualization == 1
        rect_position_vis = [pos([2,1]) - (target_sz([2,1]) - 1)/2, target_sz([2,1])];
        im_to_show = double(im)/255;
        if size(im_to_show,3) == 1
            im_to_show = repmat(im_to_show, [1 1 3]);
        end

        if frame == 1,  %first frame, create GUI
            fig_handle = figure('Name','CRCF tracker');
            imagesc(im_to_show)
            %imshow(uint8(im), 'Border','tight', 'InitialMag', 100 + 100 * (length(im) < 500));
            rectangle('Position',rect_position_vis, 'EdgeColor','g', 'LineWidth',2);
            text(10, 10, int2str(frame), 'color', [0 1 1]);
            hold on;
            resp_sz = round(norm_delta_sz*currentScaleFactor);
            xs = floor(old_pos(2)) + (1:resp_sz(2)) - floor(resp_sz(2)/2);
            ys = floor(old_pos(1)) + (1:resp_sz(1)) - floor(resp_sz(1)/2);
            resp_handle = imagesc(xs, ys, zeros(resp_sz)); colormap hsv;
            alpha(resp_handle, 0.5);
            hold off;
            axis off;axis image;set(gca, 'Units', 'normalized', 'Position', [0 0 1 1])
            if params.visualization_cmap
                cmap_handle = figure('Name', 'Color map')
            end
        else
            try  %subsequent frames, update GUI
                figure(fig_handle)
                %imshow(uint8(im), 'Border','tight', 'InitialMag', 100 + 100 * (length(im) < 500));
                imagesc(im_to_show)
                rectangle('Position',rect_position_vis, 'EdgeColor','g', 'LineWidth',2);
                text(10, 10, int2str(frame), 'color', [0 1 1]);
                hold on;
                resp_sz = round(norm_delta_sz*currentScaleFactor);
                xs = floor(old_pos(2)) + (1:resp_sz(2)) - floor(resp_sz(2)/2);
                ys = floor(old_pos(1)) + (1:resp_sz(1)) - floor(resp_sz(1)/2);
                resp_handle = imagesc(xs, ys, response); colormap hsv;
                alpha(resp_handle, 0);
                hold off;
                if params.visualization_cmap
                    figure(cmap_handle)
                    imshow(colour_map)
                end
            catch
                disp("Catch exception")
                return
            end
        end   
    drawnow
%         pause
    end
end 

fps = num_frames / time;
% disp(['fps: ' num2str(fps)])
if params.visualization == 1
    %close(fig_handle);
end

results.type = 'rect';
results.res = rect_position;
results.fps = fps;

end

% We want odd regions so that the central pixel can be exact
function y = floor_odd(x)
    y = 2*floor((x-1) / 2) + 1;
end

function out = APCE(response)
    eps = 1e-4;
    rmax = max(max(response, [], 1), [], 2);
    rmin = min(min(response, [], 1), [], 2);
    out = (rmax-rmin).^2 ./ (mean(mean((response-rmin).^2, 1), 2) + eps);
end