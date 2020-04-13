class PostsController < ApplicationController
  before_action :authenticate_user!, except: [:document, :share_q, :share_a, :help_center]
  before_action :set_post, only: [:edit, :update]
  before_action :check_permissions, only: [:edit, :update]
  before_action :verify_moderator, only: [:new, :create]

  def new
    @post = Post.new
  end

  def create
    setting_regex = /\${(?<setting_name>[^}]+)}/
    params[:post][:body_markdown] = params[:post][:body_markdown].gsub(setting_regex) do |_match|
      setting_name = $LAST_MATCH_INFO&.send(:[], :setting_name)
      if setting_name.nil?
        ''
      else
        SiteSetting[setting_name] || '(No such setting)'
      end
    end
    @post = Post.new(new_post_params.merge(body: QuestionsController.renderer.render(params[:post][:body_markdown]),
                                           user: User.find(-1)))

    if @post.policy_doc? && !current_user&.is_admin
      @post.errors.add(:base, 'You must be an administrator to create a policy document.')
      render :new, status: 403
      return
    end

    if @post.save
      redirect_to policy_path(slug: @post.doc_slug)
    else
      render :new, status: 500
    end
  end

  def edit; end

  def update
    setting_regex = /\${(?<setting_name>[^}]+)}/
    params[:post][:body_markdown] = params[:post][:body_markdown].gsub(setting_regex) do |_match|
      setting_name = $LAST_MATCH_INFO&.send(:[], :setting_name)
      if setting_name.nil?
        ''
      else
        SiteSetting[setting_name] || '(No such setting)'
      end
    end
    PostHistory.post_edited(@post, current_user, before: @post.body_markdown, after: params[:post][:body_markdown])
    if @post.update(post_params.merge(body: QuestionsController.renderer.render(params[:post][:body_markdown]),
                                      last_activity: DateTime.now, last_activity_by: current_user))
      redirect_to policy_path(slug: @post.doc_slug)
    else
      render :edit, status: 500
    end
  end

  def document
    @post = Post.find_by(doc_slug: params[:slug])
  end

  def upload
    @blob = ActiveStorage::Blob.create_after_upload!(io: params[:file], filename: params[:file].original_filename,
                                                     content_type: params[:file].content_type)
    render json: { link: url_for(@blob) }
  end

  def share_q
    redirect_to question_path(id: params[:id])
  end

  def share_a
    redirect_to question_path(id: params[:qid], anchor: "answer-#{params[:id]}")
  end

  def help_center
    @posts = Post.where(post_type_id: [PolicyDoc.post_type_id, HelpDoc.post_type_id]).order(:title)
                 .group_by(&:post_type_id).transform_values { |posts| posts.group_by(&:category) }
  end

  private

  def new_post_params
    params.require(:post).permit(:post_type_id, :title, :doc_slug, :category, :body_markdown)
  end

  def post_params
    params.require(:post).permit(:title, :category, :body_markdown)
  end

  def set_post
    @post = Post.find(params[:id])
  end

  def check_permissions
    if @post.post_type_id == HelpDoc.post_type_id
      verify_moderator
    elsif @post.post_type_id == PolicyDoc.post_type_id
      verify_admin
    else
      not_found
    end
  end
end
