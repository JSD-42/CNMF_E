function [mat_data, dims] = distribute_data(nam, patch_dims, w_overlap, memory_size_per_patch, memory_size_to_use)
% divide the field of view into multiple small patches and save the data
% into these small patches individually. There are overlaps between these
% patches.

%% default values
if ~exist(nam, 'file')
    error('File does not exist!');
end
file_name = get_fullname(nam);

if ~exist('patch_dims', 'var')
    patch_dims = [];
end
if ~exist('w_overlap', 'var') || isempty(w_overlap)
    w_overlap = 7;
end
if ~exist('memory_size_per_patch', 'var') || isempty(memory_size_per_patch)
    memory_size_per_patch = 10;
end
if ~exist('memory_size_to_use', 'var') || isempty(memory_size_to_use)
    memory_size_to_use = 30;
end

%% get the data dimension and determine the best way of distributing data
dims = get_data_dimension(file_name);
d1 = dims(1); d2 = dims(2); T = dims(3);

fprintf('\nThe data has %d X %d pixels X %d frames. \nLoading all data (double precision) requires %.3f GB RAM\n\n', d1, d2, T, prod(dims)/(2^27));

max_elements = memory_size_per_patch* (500^3); % x GB data can save x*1000^3/8 dobule numbers.
min_patch_width = 2*w_overlap+1;

if isempty(patch_dims)
    % find the optimial batch size
    patch_width = max(round(sqrt(double(round(max_elements/T))))-w_overlap*2, min_patch_width);
    patch_dims = [1, 1] * patch_width;
else
    patch_dims(patch_dims< min_patch_width) = min_patch_width;
    if length(patch_dims)==1
        patch_dims = patch_dims * [1,1];
    else
        patch_dims = patch_dims(1:2);
    end
end

patch_nums = ceil([d1/patch_dims(1), d2/patch_dims(2)]);   % number of patches for one bolumn and one row.
if patch_nums(1) < 2
    patch_idx_r = [1, d1];
else
    patch_idx_r = round(linspace(1, d1, patch_nums(1)));
end
if patch_nums(2) < 2
    patch_idx_c = [1, d2];
else
    patch_idx_c = round(linspace(1, d2, patch_nums(2)));
end
nr_patch = patch_nums(1) - 1;
nc_patch = patch_nums(1) - 1;

fprintf('The FOV is divided into %d X %d patches. \nEach patch has around %d X %d pixels. \n',...
    nr_patch, nc_patch, patch_dims(1), patch_dims(2));
fprintf('It requires %.3f GB RAM for loading data related to each patch. \n\n', prod(patch_dims+2*w_overlap)*T/(2^27));

%% indices for dividing the FOV into multiple blocks.
block_idx_r = bsxfun(@plus, patch_idx_r, w_overlap*[-1; 1]);
block_idx_c = bsxfun(@plus, patch_idx_c, w_overlap*[-1; 1]);
block_idx_r = block_idx_r(:);
block_idx_c = block_idx_c(:);
block_idx_r(block_idx_r<1) = 1; block_idx_r(block_idx_r>d1) = d1;
block_idx_c(block_idx_c<1) = 1; block_idx_c(block_idx_c>d2) = d2;
block_idx_r = sort(unique(block_idx_r));
block_idx_c = sort(unique(block_idx_c));
nr_block = length(block_idx_r) - 1;
nc_block = length(block_idx_c) - 1;
% num_blocks = nr_block * nc_block;

%% prepare for distributing the data into multiple patches.
[dir_nm, file_nm, ~] = fileparts(file_name);
folder_analysis = [dir_nm, filesep, file_nm, '_source_extraction'];
mat_file = [folder_analysis, filesep,...
    sprintf('data_%d_%d_%d.mat', patch_dims(1), patch_dims(2), w_overlap)];

if ~exist(folder_analysis, 'dir')
    mkdir(folder_analysis);
end

% check whether the mat data has been created
if exist(mat_file, 'file')
    mat_data = matfile(mat_file);
    fprintf('The data has been saved into \n%s\n\n', mat_file); 
    return;
end

% create a mat file and save data info into it. 
mat_data = matfile(mat_file, 'Writable', true);
save(mat_file, 'file_name', '-v7.3');
mat_data.patch_idx_r = patch_idx_r;
mat_data.patch_idx_c = patch_idx_c;
mat_data.nr_patch = nr_patch; 
mat_data.nc_patch = nc_patch; 
mat_data.block_idx_r = block_idx_r;
mat_data.block_idx_c = block_idx_c;
mat_data.nr_block = nr_block; 
mat_data.nc_block = nc_block; 
mat_data.w_overlap = w_overlap;
mat_data.dims = dims;

% pre-allocate matrices for saving the video data 
img = smod_bigread2(file_name,1,1);
default_value = 0*img(1);
temp = whos('img');
mat_data.dtype = temp.class;
for m=1:nr_block
    r0 = block_idx_r(m);
    r1 = block_idx_r(m+1);
    nr = r1-r0+1;
    for n=1:nc_block
        c0 = block_idx_c(n);
        c1 = block_idx_c(n+1);
        nc = c1-c0+1;
        eval(sprintf('mat_data.Y_%d_%d_%d_%d(%d, %d, %d)=default_value;', r0, r1, c0, c1, nr, nc, T));
    end
end


% positions for determing a batch and the minimum block that includes the
% patch 
patch_pos = cell(nr_patch, nc_patch); 
block_pos = cell(nr_patch, nc_patch); 
for m=1:nr_patch 
    for n=1:nc_patch 
        patch_pos{m, n} = [patch_idx_r(m:(m+1)), patch_idx_c(n:(n+1))]; 
        block_pos{m, n} = [max(1, patch_idx_r(m)-w_overlap), min(d1, patch_idx_r(m+1)+w_overlap), ...
            max(1, patch_idx_c(n)-w_overlap), min(d2, patch_idx_c(n+1)+w_overlap)]; 
    end 
end 
mat_data.patch_pos = patch_pos; 
mat_data.block_pos = block_pos; 
%% load and distribute data 
Tchunk = floor(memory_size_to_use * (500^3) / (d1*d2));
t_start= 0;
fprintf('\n-------- Loading --------\n'); 
fprintf('Data is being loaded and distributed into multiple small blocks for easy access.\n\n'); 

while t_start<T
    num2read = min(Tchunk, T-t_start);
    Y = smod_bigread2(file_name, t_start, num2read);
    for m=1:nr_block
        r0 = block_idx_r(m);
        r1 = block_idx_r(m+1);
        nr = r1-r0+1; %#ok<*NASGU>
        for n=1:nc_block
            c0 = block_idx_c(n);
            c1 = block_idx_c(n+1);
            nc = c1-c0+1;
            eval(sprintf('mat_data.Y_%d_%d_%d_%d(1:nr, 1:nc, %d:%d)=Y(%d:%d, %d:%d, :); ', ...
                r0, r1, c0, c1, t_start+1, t_start+num2read, r0, r1, c0, c1));
        end
    end
    t_start = t_start + num2read;
    fprintf('load %d out of %d frames\n', t_start, T); 
end
fprintf('\nThe data has been saved into \n%s\n', mat_file); 
fprintf('\n-------- Done --------\n'); 


