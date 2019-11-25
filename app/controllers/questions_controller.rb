# Web controller. Provides actions that relate to questions - this is essentially the standard set of resources, plus a
# couple for the extra question lists (such as listing by tag).
class QuestionsController < ApplicationController
  before_action :authenticate_user!, only: [:new, :create, :edit, :update, :destroy, :undelete, :close, :reopen]
  before_action :set_question, only: [:show, :edit, :update, :destroy, :undelete, :close, :reopen]
  @@markdown_renderer = Redcarpet::Markdown.new(Redcarpet::Render::HTML.new(), extensions = {})

  def self.renderer
    @@markdown_renderer
  end

  def index
    @questions = Question.undeleted.order('updated_at DESC').paginate(page: params[:page], per_page: 25)
  end

  def show
    if @question.deleted?
      check_your_privilege('ViewDeleted', @question) or return
    end
    @votes = @question.votes.group(:vote_type).count(:vote_type)
    @answers = if current_user&.has_privilege?('ViewDeleted')
                 @question.answers
               else
                 @question.answers.undeleted
               end.includes(:votes).order(Arel.sql('score DESC'))
  end

  def tagged
    @questions = Question.where('tags like ?', "%#{params[:tag]}%").order('updated_at DESC').paginate(page: params[:page], per_page: 50)
  end

  def new
    @question = Question.new
  end

  def create
    params[:question][:tags] = params[:question][:tags].split(" ")
    @question = Question.new question_params
    @question.tags = params[:question][:tags]
    @question.user = current_user
    @question.score = 0
    if @question.save
      redirect_to url_for(controller: :questions, action: :show, id: @question.id)
    else
      render :new, status: 400
    end
  end

  def edit
    return unless check_your_privilege('Edit', @question)
  end

  def update
    return unless check_your_privilege('Edit', @question)
    params[:question][:tags] = params[:question][:tags].split(" ")
    PostHistory.post_edited(@question, current_user)
    if @question.update question_params
      @question.tags = params[:question][:tags]
      if @question.save
        redirect_to url_for(controller: :questions, action: :show, id: @question.id)
      else
        render :edit
      end
    else
      render :edit
    end
  end

  def destroy
    return unless check_your_privilege('Delete', @question)
    PostHistory.post_deleted(@question, current_user)
    @question.deleted = true
    @question.deleted_at = DateTime.now
    if @question.save
      calculate_reputation(@question.user, @question, -1)
      redirect_to url_for(controller: :questions, action: :show, id: @question.id)
    else
      flash[:error] = "The question could not be deleted."
      redirect_to url_for(controller: :questions, action: :show, id: @question.id)
    end
  end

  def undelete
    return unless check_your_privilege('Delete', @question)
    PostHistory.post_undeleted(@question, current_user)
    @question.deleted = false
    @question.deleted_at = DateTime.now
    if @question.save
      calculate_reputation(@question.user, @question, 1)
      redirect_to url_for(controller: :questions, action: :show, id: @question.id)
    else
      flash[:error] = "The question could not be undeleted."
      redirect_to url_for(controller: :questions, action: :show, id: @question.id)
    end
  end

  def feed
    @questions = Rails.cache.fetch("questions_rss", expires_in: 5.minutes) do
      Question.all.order(created_at: :desc).limit(25)
    end
    respond_to do |format|
      format.rss { render layout: false }
    end
  end

  def close
    unless check_your_privilege('Close', nil, false)
      render json: {status: 'failed', message: 'You must have the Close privilege to close questions.'}, status: 401 and return
    end

    if @question.closed
      render json: {status: 'failed', message: 'Cannot close a closed question.'}, status: 422 and return
    end

    if @question.update(closed: true, closed_by: current_user, closed_at: Time.now)
      PostHistory.question_closed(@question, current_user)
      render json: {status: 'success', closed_by: "<a href='/users/#{current_user.id}'>#{current_user.username}</a>"}
    else
      render json: {status: 'failed', message: 'Question state could not be saved.'}, status: 500
    end
  end

  def reopen
    unless check_your_privilege('Close', nil, false)
      render json: {status: 'failed', message: 'You must have the Close privilege to reopen questions.'}, status: 401 and return
    end

    if !@question.closed
      render json: {status: 'failed', message: 'Cannot reopen an open question.'}, status: 422 and return
    end

    if @question.update(closed: false, closed_by: current_user, closed_at: Time.now)
      PostHistory.question_reopened(@question, current_user)
      render json: {status: 'success'}
    else
      render json: {status: 'failed', message: 'Question state could not be saved.'}, status: 500
    end
  end

  private

  def question_params
    params.require(:question).permit(:body, :title, :tags)
  end

  def set_question
    begin
      @question = Question.find params[:id]
    rescue
      if current_user.has_privilege?('ViewDeleted')
        @question ||= Question.unscoped.find params[:id]
      end
      if @question.nil?
        render template: 'errors/not_found', status: 404
      end
    end
  end

  def calculate_reputation(user, post, direction)
    upvote_rep = post.votes.where(vote_type: 1).count * SiteSetting['QuestionUpVoteRep']
    downvote_rep = post.votes.where(vote_type: -1).count * SiteSetting['QuestionDownVoteRep']
    user.reputation += direction * (upvote_rep + downvote_rep)
    user.save!
  end
end

# Provides a custom HTML sanitization interface to use for cleaning up the HTML in questions.
class QuestionScrubber < Rails::Html::PermitScrubber
  def initialize
    super
    self.tags = %w( a p b i em strong hr h1 h2 h3 h4 h5 h6 blockquote img strike del code pre br ul ol li )
    self.attributes = %w( href title src height width )
  end

  def skip_node?(node)
    node.text?
  end
end
