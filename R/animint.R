#' Convert a ggplot to a list. 
#' @param meta environment with previously calculated plot data, and a new plot to parse, already stored in plot and plot.name.
#' @return nothing, info is stored in meta.
#' @export
parsePlot <- function(meta){
  meta$built <- ggplot2::ggplot_build(meta$plot)
  plot.meta <- list()
  scaleFuns <-
    list(manual=function(sc)sc$palette(0),
         brewer=function(sc)sc$palette(length(sc$range$range)),
         hue=function(sc)sc$palette(length(sc$range$range)),
         linetype_d=function(sc)sc$palette(length(sc$range$range)),
         alpha_c=function(sc)sc$palette(sc$range$range),
         size_c=function(sc)sc$palette(sc$range$range),
         gradient=function(sc){
           ggplot2:::scale_map(sc, ggplot2:::scale_breaks(sc))
         })
  for(sc in meta$plot$scales$scales){
    if(!is.null(sc$range$range)){
      makeScale <- scaleFuns[[sc$scale_name]]
      plot.meta$scales[[sc$aesthetics]] <- makeScale(sc)
    }
  }
  for(layer.i in seq_along(meta$plot$layers)){
    ##cat(sprintf("%4d / %4d layers\n", layer.i, length(meta$plot$layers)))
    
    ## This is the layer from the original ggplot object.
    L <- meta$plot$layers[[layer.i]]

    ## for each layer, there is a correpsonding data.frame which
    ## evaluates the aesthetic mapping.
    df <- meta$built$data[[layer.i]]

    ## This extracts essential info for this geom/layer.
    g <- saveLayer(L, df, meta)

    plot.meta$geoms <- c(plot.meta$geoms, list(g$classed))
  }
  ## For each geom, save the nextgeom to preserve drawing order.
  n.next <- length(plot.meta$geoms) - 1
  if(n.next){
    for(geom.i in 1:n.next){
      geom.prev <- plot.meta$geoms[[geom.i]]
      geom.next <- plot.meta$geoms[[geom.i + 1]]
      meta$geoms[[geom.prev]]$nextgeom <- meta$geoms[[geom.next]]$classed
    }
  }
                                        
  ## Export axis specification as a combination of breaks and
  ## labels, on the relevant axis scale (i.e. so that it can
  ## be passed into d3 on the x axis scale instead of on the 
  ## grid 0-1 scale). This allows transformations to be used 
  ## out of the box, with no additional d3 coding. 
  theme.pars <- ggplot2:::plot_theme(meta$plot)  
  
  ## Flip labels if coords are flipped - transform does not take care
  ## of this. Do this BEFORE checking if it is blank or not, so that
  ## individual axes can be hidden appropriately, e.g. #1.
  if(nrow(meta$built$panel$layout) > 1){
    stop("animint does not yet support facets")
  }
  ranges <- meta$built$panel$ranges[[1]]
  if("flip"%in%attr(meta$plot$coordinates, "class")){
    temp <- meta$plot$labels$x
    meta$plot$labels$x <- meta$plot$labels$y
    meta$plot$labels$y <- temp
  }
  is.blank <- function(el.name){
    x <- ggplot2::calc_element(el.name, meta$plot$theme)
    "element_blank"%in%attr(x,"class")
  }
  plot.meta$axis <- list()
  for(xy in c("x","y")){
    s <- function(tmp)sprintf(tmp, xy)
    plot.meta$axis[[xy]] <- ranges[[s("%s.major")]]
    plot.meta$axis[[s("%slab")]] <- if(is.blank(s("axis.text.%s"))){
      NULL
    }else{
      ranges[[s("%s.labels")]]
    }
    plot.meta$axis[[s("%srange")]] <- ranges[[s("%s.range")]]
    plot.meta$axis[[s("%sname")]] <- if(is.blank(s("axis.title.%s"))){
      ""
    }else{
      scale.i <- which(meta$plot$scales$find(xy))
      lab.or.null <- if(length(scale.i) == 1){
        meta$plot$scales$scales[[scale.i]]$name
      }
      if(is.null(lab.or.null)){
        meta$plot$labels[[xy]]
      }else{
        lab.or.null
      }
    }
    plot.meta$axis[[s("%sline")]] <- !is.blank(s("axis.line.%s"))
    plot.meta$axis[[s("%sticks")]] <- !is.blank(s("axis.ticks.%s"))
  }

  plot.meta$legend <- getLegendList(meta$built)
  if(length(plot.meta$legend)>0){
    plot.meta$legend <-
      plot.meta$legend[which(sapply(plot.meta$legend, function(i) {
        length(i)>0
      }))]
  }  # only pass out legends that have guide = "legend" or guide="colorbar"
  
  # Remove legend if theme has no legend position
  if(theme.pars$legend.position=="none") plot.meta$legend <- NULL
  
  if("element_blank"%in%attr(theme.pars$plot.title, "class")){
    plot.meta$title <- ""
  } else {
    plot.meta$title <- meta$plot$labels$title
  }

  ## Set plot width and height from animint.* options if they are
  ## present.
  plot.meta$options <- list()
  theme <- meta$plot$theme
  for(wh in c("width", "height")){
    awh <- paste0("animint.", wh)
    plot.meta$options[[wh]] <- if(awh %in% names(theme)){
      theme[[awh]]
    }else{
      400
    }
  }

  meta$plots[[meta$plot.name]] <- plot.meta
}

#' Save a layer to disk, save and return meta-data.
#' @param l one layer of the ggplot object.
#' @param d one layer of calculated data from ggplot2::ggplot_build(p).
#' @param meta environment of meta-data.
#' @return list representing a layer, with corresponding aesthetics, ranges, and groups.
#' @export
saveLayer <- function(l, d, meta){
  ranges <- meta$built$panel$ranges[[1]] #TODO:facets
  g <- list(geom=l$geom$objname)
  g.data <- d
  g$classed <-
    sprintf("geom%d_%s_%s",
            meta$geom.count, g$geom, meta$plot.name)
  meta$geom.count <- meta$geom.count + 1
  ## needed for when group, etc. is an expression:
  g$aes <- sapply(l$mapping, function(k) as.character(as.expression(k))) 

  ## use un-named parameters so that they will not be exported
  ## to JSON as a named object, since that causes problems with
  ## e.g. colour.
  g$params <- c(l$geom_params, l$stat_params)
  for(p.name in names(g$params)){
    names(g$params[[p.name]]) <- NULL
    ## Ignore functions.
    if(is.function(g$params[[p.name]])){
      g$params[[p.name]] <- NULL
    }
  }

  ## Make a list of variables to use for subsetting. subset_order is the
  ## order in which these variables will be accessed in the recursive
  ## JavaScript array structure.

  ## subset_order IS in fact useful with geom_segment! For example, in
  ## the first plot in the breakpointError example, the geom_segment has
  ## the following exported data in plot.json

  ## "subset_order": [
  ##  "showSelected",
  ## "showSelected2" 
  ## ],

  ## This information is used to parse the recursive array data structure
  ## that allows efficient lookup of subsets of data in JavaScript. Look at
  ## the Firebug DOM browser on
  ## http://sugiyama-www.cs.titech.ac.jp/~toby/animint/breakpoints/index.html
  ## and navigate to plot.Geoms.geom3.data. You will see that this is a
  ## recursive array that can be accessed via
  ## data[segments][bases.per.probe] which is an un-named array
  ## e.g. [{row1},{row2},...] which will be bound to the <line> elements by
  ## D3. The key point is that the subset_order array stores the order of the
  ## indices that will be used to select the current subset of data (in
  ## this case showSelected=segments, showSelected2=bases.per.probe). The
  ## currently selected values of these variables are stored in
  ## plot.Selectors.

  is.ss <- is.showSelected(names(g$aes))
  show.vars <- g$aes[is.ss]
  g$subset_order <- as.list(names(show.vars))

  is.cs <- names(g$aes) == "clickSelects"
  update.vars <- g$aes[is.ss | is.cs]

  ## Construct the selector.
  for(sel.i in seq_along(update.vars)){
    v.name <- update.vars[[sel.i]]
    col.name <- names(update.vars)[[sel.i]]
    if(!v.name %in% names(meta$selectors)){
      ## select the first one. TODO: customize.
      value <- g.data[[col.name]][1]
      meta$selectors[[v.name]] <- list(selected=as.character(value))
    }
    meta$selectors[[v.name]]$update <-
      c(meta$selectors[[v.name]]$update, as.list(g$classed))
  }
  
  ## Warn if stat_bin is used with animint aes. geom_bar + stat_bin
  ## doesn't make sense with clickSelects/showSelected, since two
  ## clickSelects/showSelected values may show up in the same bin.
  stat <- l$stat
  if(!is.null(stat)){
    is.bin <- stat$objname=="bin"
    is.animint.aes <- grepl("clickSelects|showSelected", names(g$aes))
    if(is.bin & any(is.animint.aes)){
      warning(paste0("stat_bin is unpredictable ",
                    "when used with clickSelects/showSelected.\n",
                     "Use ddply to do the binning ",
                     "or use make_bar if using geom_bar/geom_histogram."))
    }
  }

  ##print("before pre-processing")
  
  ## Pre-process some complex geoms so that they are treated as
  ## special cases of basic geoms. In ggplot2, this processing is done
  ## in the draw method of the geoms.
  if(g$geom=="abline"){
    # "Trick" ggplot coord_transform into transforming the slope and intercept
    g.data[,"x"] <- ranges$x.range[1]
    g.data[,"xend"] <- ranges$x.range[2]
    g.data[,"y"] <- g.data$slope*ranges$x.range[1]+g.data$intercept
    g.data[,"yend"] <-  g.data$slope*ranges$x.range[2]+g.data$intercept
    g.data <- as.data.frame(g.data)
    if(g$aes[["group"]]=="1"){ 
      # ggplot2 defaults to adding a group attribute
      # which misleads for situations where there are 
      # multiple lines with the same group. 
      # if the group attribute conveys no additional 
      # information, remove it.
      ## TODO: Figure out a better way to handle this...
      g$aes <- g$aes[-which(names(g$aes)=="group")]
    } 
    g$geom <- "segment"
  } else if(g$geom=="point"){
    # Fill set to match ggplot2 default of filled in circle. 
    if(!"fill"%in%names(g.data) & "colour"%in%names(g.data)){
      g.data[["fill"]] <- g.data[["colour"]]
    }
    ## group is meaningless for points, so delete it.
    g.data <- g.data[names(g.data) != "group"]
  } else if(g$geom=="segment"){
    ## group is meaningless for segments, so delete it.
    g.data <- g.data[names(g.data) != "group"]
  } else if(g$geom=="text"){
    ## group is meaningless for text, so delete it.
    g.data <- g.data[names(g.data) != "group"]
  } else if(g$geom=="rect"){
    ## group is meaningless for rects, so delete it.
    g.data <- g.data[names(g.data) != "group"]
  } else if(g$geom=="ribbon"){
    # Color set to match ggplot2 default of fill with no outside border.
    if("fill"%in%names(g.data) & !"colour"%in%names(g.data)){
      g.data[["colour"]] <- g.data[["fill"]]
    }
  } else if(g$geom=="density" | g$geom=="area"){
    g$geom <- "ribbon"
  } else if(g$geom=="tile" | g$geom=="raster" | g$geom=="histogram" ){
    # Color set to match ggplot2 default of tile with no outside border.
    if(!"colour"%in%names(g.data) & "fill"%in%names(g.data)){
      g.data[["colour"]] <- g.data[["fill"]]
      # Make outer border of 0 size if size isn't already specified.
      if(!"size"%in%names(g.data)) g.data[["size"]] <- 0 
    }
    g$geom <- "rect"
  } else if(g$geom=="bar"){
    g$geom <- "rect"
  } else if(g$geom=="bin2d"){
    stop("bin2d is not supported in animint. Try using geom_tile() and binning the data yourself.")
  } else if(g$geom=="boxplot"){
    stop("boxplots are not supported. Workaround: rects, lines, and points")
    ## TODO: boxplot support. But it is hard since boxplots are drawn
    ## using multiple geoms and it is not straightforward to deal with
    ## that using our current JS code. There is a straightforward
    ## workaround: combine working geoms (rects, lines, and points).

    g.data$outliers <- sapply(g.data$outliers, FUN=paste, collapse=" @ ") 
    # outliers are specified as a list... change so that they are specified 
    # as a single string which can then be parsed in JavaScript.
    # there has got to be a better way to do this!!
  } else if(g$geom=="violin"){
    x <- g.data$x
    vw <- g.data$violinwidth
    xmin <- g.data$xmin
    xmax <- g.data$xmax
    g.data$xminv <- x-vw*(x-xmin)
    g.data$xmaxv <- x+vw*(xmax-x)
    newdata <- ddply(g.data, .(group), function(df){
                  rbind(arrange(transform(df, x=xminv), y), arrange(transform(df, x=xmaxv), -y))
                })
    newdata <- ddply(newdata, .(group), function(df) rbind(df, df[1,]))
    g.data <- newdata
    g$geom <- "polygon"
  } else if(g$geom=="step"){
    datanames <- names(g.data)
    g.data <- ddply(g.data, .(group), function(df) ggplot2:::stairstep(df))
    g$geom <- "path"
  } else if(g$geom=="contour" | g$geom=="density2d"){
    g$aes[["group"]] <- "piece"
    g$geom <- "path"
  } else if(g$geom=="freqpoly"){
    g$geom <- "line"
  } else if(g$geom=="quantile"){
    g$geom <- "path"
  } else if(g$geom=="hex"){
    g$geom <- "polygon"
    ## TODO: for interactivity we will run into the same problems as
    ## we did with histograms. Again, if we put several
    ## clickSelects/showSelected values in the same hexbin, then
    ## clicking/hiding hexbins doesn't really make sense. Need to stop
    ## with an error if showSelected/clickSelects is used with hex.
    g$aes[["group"]] <- "group"
    dx <- ggplot2::resolution(g.data$x, FALSE)
    dy <- ggplot2::resolution(g.data$y, FALSE) / sqrt(3) / 2 * 1.15
    hex <- as.data.frame(hexcoords(dx, dy))[,1:2]
    hex <- rbind(hex, hex[1,]) # to join hexagon back to first point
    g.data$group <- as.numeric(interaction(g.data$group, 1:nrow(g.data)))
    ## this has the potential to be a bad assumption - 
    ##   by default, group is identically 1, if the user 
    ##   specifies group, polygons aren't possible to plot
    ##   using d3, because group will have a different meaning
    ##   than "one single polygon".
    newdata <- ddply(g.data, .(group), function(df){
      df$xcenter <- df$x
      df$ycenter <- df$y
      cbind(x=df$x+hex$x, y=df$y+hex$y, df[,-which(names(df)%in%c("x", "y"))])
    })
    g.data <- newdata
    # Color set to match ggplot2 default of tile with no outside border.
    if(!"colour"%in%names(g.data) & "fill"%in%names(g.data)){
      g.data[["colour"]] <- g.data[["fill"]]
      # Make outer border of 0 size if size isn't already specified.
      if(!"size"%in%names(g.data)) g.data[["size"]] <- 0 
    }
  } else { 
    ## all other geoms are basic, and keep the same name.
    g$geom
  }

  ##print("after pre-processing")
  
  ## idea: if geom is calculated, group is not meaningful - 
  ## it has already been used in the calculation stage, and 
  ## will only confuse the issue later.
  geom.aes.vars = g$aes[which(names(g$aes)%in%c("x", "y", "fill", "colour", "alpha", "size"))]
  grpidx <- which(names(g$aes)=="group")
  if(length(grpidx) > 0){
    if(length(geom.aes.vars)>0 & nrow(g.data)!=nrow(l$data) & 
         !g$geom%in%c("ribbon","polygon","line", "path")){
      ## need to exclude geom_ribbon and geom_violin, since they are
      ## coded to allow group aesthetics because they use the d3 path
      ## setup.
      if(g$aes[grpidx]%in%geom.aes.vars){
        ## if the group aesthetic is also mapped to another visual aesthetic, 
        ## then remove the group aesthetic
        g$aes <- g$aes[-which(names(g$aes)=="group")]
      }
    }
  }
  
  ##print("after group block")
  
  ## Check g.data for color/fill - convert to hexadecimal so JS can parse correctly.
  for(color.var in c("colour", "color", "fill")){
    if(color.var %in% names(g.data)){
      g.data[,color.var] <- toRGB(g.data[,color.var])
    }
  }

  if(any(g.data$size == 0, na.rm=TRUE)){
    warning(sprintf("geom_%s with size=0 will be invisible",g$geom))
  }
  
  ## Idea: use the ggplot2:::coord_transform(coords, data, scales)
  ## function to handle cases like coord_flip. scales is a list of
  ## 12, coords is a list(limits=list(x=NULL,y=NULL)) with class
  ## e.g. c("cartesian","coord"). The result is a transformed data
  ## frame where all the data values are between 0 and 1.
  
  ## TODO: coord_transform maybe won't work for 
  ## geom_dotplot|rect|segment and polar/log transformations, which
  ## could result in something nonlinear. For the time being it is
  ## best to just ignore this, but you can look at the source of
  ## e.g. geom-rect.r in ggplot2 to see how they deal with this by
  ## doing a piecewise linear interpolation of the shape.

  g.data <-
    ggplot2:::coord_transform(meta$plot$coord,
                              g.data,
                              ranges)
  
  ## TODO:facets. Right now we delete PANEL info since it just takes
  ## up space for no reason in the CSV database.
  g.data <- g.data[names(g.data) != "PANEL"]

  ## Output types
  ## Check to see if character type is d3's rgb type. 
  is.linetype <- function(x){
    x <- tolower(x)
    namedlinetype <-
      x%in%c("blank", "solid", "dashed",
             "dotted", "dotdash", "longdash", "twodash")
    xsplit <- sapply(x, function(i){
      sum(is.na(strtoi(strsplit(i,"")[[1]],16)))==0
    })
    namedlinetype | xsplit
  }
  g$types <- sapply(g.data, function(x) {
    type <- paste(class(x), collapse="-")
    if(type == "character"){
      if(sum(!is.rgb(x))==0){
        "rgb"
      }else if(sum(!is.linetype(x))==0){
        "linetype"
      }else {
        "character"
      }
    }else{
      type
    }
  })
  
  ## convert ordered factors to unordered factors so javascript
  ## doesn't flip out.
  ordfactidx <- which(g$types=="ordered-factor")
  for(i in ordfactidx){
    g.data[[i]] <- factor(as.character(g.data[[i]]))
    g$types[[i]] <- "factor"
  }

  ## Make the time variable the first subset_order variable.
  time.col <- if(is.null(meta$time)){ # if this is not an animation,
    NULL
  }else{
    click.or.show <- grepl("clickSelects|showSelected", names(g$aes))
    names(g$aes)[g$aes==meta$time$var & click.or.show]
  }
  if(length(time.col)){
    g$subset_order <- g$subset_order[order(g$subset_order != time.col)]
  }
  
  ## Determine which showSelected values to use for breaking the data
  ## into chunks. This is a list of variables which have the same
  ## names as the selectors. E.g. if chunk_order=list("year") then
  ## when year is clicked, we may need to download some new data for
  ## this geom.

  ## Old code which allows several chunk variables:
  ## nest.cols <- NULL
  ## chunk.cols <- if(length(g$subset_order)){
  ##   vec.list <- g.data[unlist(g$subset_order)]
  ##   counts <- do.call(table, vec.list)
  ##   if(all(counts == 1)){
  ##     nest.cols <- names(vec.list)[length(vec.list)]
  ##     names(vec.list)[-length(vec.list)]
  ##   }else{
  ##     names(vec.list)
  ##   }
  ## }

  subset.vec <- unlist(g$subset_order)
  if("chunk_vars" %in% names(g$params)){ #designer-specified chunk vars.
    designer.chunks <- g$params$chunk_vars
    if(!is.character(designer.chunks)){
      stop("chunk_vars must be a character vector; ",
           "use chunk_vars=character() to specify 1 chunk")
    }
    not.subset <- !designer.chunks %in% g$aes[subset.vec]
    if(any(not.subset)){
      stop("invalid chunk_vars ",
           paste(designer.chunks[not.subset], collapse=" "),
           "; possible showSelected variables: ",
           paste(g$aes[subset.vec], collapse=" "))
    }
    is.chunk <- g$aes[subset.vec] %in% designer.chunks
    chunk.cols <- subset.vec[is.chunk]
    nest.cols <- subset.vec[!is.chunk]
  }else{ #infer a default, either 0 or 1 chunk vars:
    several.chunks <- if(length(g$subset_order)){
      chunk.var <- subset.vec[[1]]
      chunk.vec <- g.data[[chunk.var]]
      counts <- table(chunk.vec)
      if(length(counts) == 1){
        stop("only 1 chunk") # do we ever get here?
      }
      if(all(counts == 1)){
        FALSE #each chunk has only 1 row -- chunks are too small.
      }else{
        TRUE
      }
    }else{
      FALSE
    }
    if(several.chunks){
      nest.cols <- subset.vec[-1]
      chunk.cols <- chunk.var
    }else{
      nest.cols <- subset.vec
      chunk.cols <- NULL
    }
  }

  ## Split into chunks and save tsv files.
  meta$classed <- g$classed
  meta$chunk.i <- 1L
  g$chunks <- saveChunks(g.data, chunk.cols, meta)
  g$total <- length(unlist(g$chunks))

  ## Also add pointers to these chunks to the related selectors.
  if(length(chunk.cols)){
    selector.names <- as.character(g$aes[chunk.cols])
    chunk.name <- paste(selector.names, collapse="_")
    g$chunk_order <- as.list(selector.names)
    for(selector.name in selector.names){
      meta$selectors[[selector.name]]$chunks <-
        unique(c(meta$selectors[[selector.name]]$chunks, chunk.name))
    }
  }else{
    g$chunk_order <- list()
  }
  g$nest_order <- as.list(nest.cols)
  names(g$chunk_order) <- NULL
  names(g$nest_order) <- NULL
  g$subset_order <- g$nest_order
  if("group" %in% names(g$aes)){
    g$nest_order <- c(g$nest_order, "group")
  }
  
  ## Get unique values of time variable.
  if(length(time.col)){ # if this layer/geom is animated,
    g$timeValues <- unique(g.data[[time.col]])
  }

  ## TODO: save the download order... if it is an animation then the
  ## download order should be in the same order.

  ## Finally save to the master geom list.
  meta$geoms[[g$classed]] <- g

  g
}

##' Split data set into chunks and save them to separate files.
##' @param x data.frame.
##' @param vars character vector of variable names to split on.
##' @param meta environment.
##' @return recursive list of chunk file names.
##' @author Toby Dylan Hocking
saveChunks <- function(x, vars, meta){
  if(is.data.frame(x)){
    if(length(vars) == 0){
      this.i <- meta$chunk.i
      csv.name <- sprintf("%s_chunk%d.tsv", meta$classed, this.i)
      meta$chunk.i <- meta$chunk.i + 1L
      write.table(x,
                  file.path(meta$out.dir, csv.name),
                  quote=FALSE, row.names=FALSE, sep="\t")
      this.i
    }else{
      use <- vars[[1]]
      rest <- vars[-1]
      vec <- x[[use]]
      df.list <- split(x[names(x) != use], vec, drop=TRUE)
      saveChunks(df.list, rest, meta)
    }
  }else if(is.list(x)){
    lapply(x, saveChunks, vars, meta)
  }else{
    str(x)
    stop("unknown object")
  }
}

##' Test if aesthetics are showSelected.
##' @param x character vector.
##' @return logical vector
##' @export
##' @author Toby Dylan Hocking
is.showSelected <- function(x){
  if(length(x) == 0)return(logical())
  stopifnot(is.character(x))
  grepl("showSelected", x)
}

##' Deprecated alias for animint2dir.
##' @title animint2dir
##' @param ... passed to animint2dir
##' @return same as animint2dir
##' @author Toby Dylan Hocking
##' @export
gg2animint <- function(...){
  warning("gg2animint is deprecated, use animint2dir instead")
  animint2dir(...)
}

#' Compile and render an animint in a local directory
#'
#' An animint is a list of ggplots and options that defines
#' an interactive animation and can be viewed in a web browser. 
#' Several new aesthetics control interactivity.
#' The most important two are 
#' \itemize{
#' \item \code{aes(showSelected=variable)} means that
#'   only the subset of the data that corresponds to
#'   the selected value of variable will be shown.
#' \item \code{aes(clickSelects=variable)} means that clicking
#'   this geom will change the currently selected value of variable.
#' }
#' The others are described on https://github.com/tdhock/animint/wiki/Advanced-features-present-animint-but-not-in-ggplot2
#' 
#' Supported ggplot2 geoms: 
#' \itemize{
#' \item point 
#' \item jitter
#' \item line
#' \item rect
#' \item tallrect (new with this package)
#' \item segment
#' \item hline
#' \item vline
#' \item bar
#' \item text
#' \item tile
#' \item raster
#' \item ribbon
#' \item abline
#' \item density
#' \item path
#' \item polygon
#' \item histogram
#' \item violin
#' \item linerange
#' \item step
#' \item contour
#' \item density2d
#' \item area
#' \item freqpoly
#' \item hex
#' }
#' Unsupported geoms: 
#' \itemize{
#' \item rug
#' \item dotplot
#' \item quantile - should *theoretically* work but in practice does not work
#' \item smooth - can be created using geom_line and geom_ribbon
#' \item boxplot - can be created using geom_rect and geom_segment
#' \item crossbar - can be created using geom_rect and geom_segment
#' \item pointrange - can be created using geom_linerange and geom_point
#' \item bin2d - bin using ddply() and then use geom_tile()
#' \item map - can be created using geom_polygon or geom_path
#'}
#' Supported scales: 
#' \itemize{
#' \item alpha, 
#' \item fill/colour (brewer, gradient, identity, manual)
#' \item linetype
#' \item x and y axis scales, manual break specification, label formatting
#' \item x and y axis theme elements: axis.line, axis.ticks, axis.text, axis.title can be set to element_blank(); other theme modifications not supported at this time, but would be possible with custom css files.
#' \item area 
#' \item size
#' }
#' Unsupported scales: 
#' \itemize{
#' \item shape. Open and closed circles can be represented by manipulating fill and colour scales and using default (circle) points, but d3 does not support many R shape types, so mapping between the two is difficult.
#' }
#' 
#' @aliases animint
#' @param plot.list a named list of ggplots and option lists.
#' @param out.dir directory to store html/js/csv files.
#' @param json.file character string that names the JSON file with metadata associated with the plot.
#' @param open.browser Should R open a browser? If yes, be sure to configure your browser to allow access to local files, as some browsers block this by default (e.g. chrome).
#' @return invisible list of ggplots in list format.
#' @export 
#' @seealso \code{\link{ggplot2}}
#' @example examples/animint.R
animint2dir <- function(plot.list, out.dir=tempfile(), json.file = "plot.json", open.browser=interactive()){
  ## Check that it is a list and every element is named.
  stopifnot(is.list(plot.list))
  stopifnot(!is.null(names(plot.list)))
  stopifnot(all(names(plot.list)!=""))
  
  ## Store meta-data in this environment, so we can alter state in the
  ## lower-level functions.
  meta <- new.env()
  meta$plots <- list()
  meta$geoms <- list()
  meta$selectors <- list()
  dir.create(out.dir,showWarnings=FALSE)
  meta$out.dir <- out.dir
  meta$geom.count <- 1

  ## Save the animation variable so we can treat it specially when we
  ## process each geom.
  if(is.list(plot.list$time)){
    meta$time <- plot.list$time
    ms <- meta$time$ms
    stopifnot(is.numeric(ms))
    stopifnot(length(ms)==1)
    ## NOTE: although we do not use olist$ms for anything in the R
    ## code, it is used to control the number of milliseconds between
    ## animation frames in the JS code.
    time.var <- meta$time$variable
    stopifnot(is.character(time.var))
    stopifnot(length(time.var)==1)
  }

  ## The title option should just be a character, not a list.
  if(is.list(plot.list$title)){
    plot.list$title <- plot.list$title[[1]]
  }
  if(is.character(plot.list$title)){
    meta$title <- plot.list$title[[1]]
    plot.list$title <- NULL
  }

  ## Extract essential info from ggplots, reality checks.
  for(list.name in names(plot.list)){
    p <- plot.list[[list.name]]
    if(is.ggplot(p)){
      pattern <- "^[a-zA-Z][a-zA-Z0-9]*$"
      if(!grepl(pattern, list.name)){
        stop("ggplot names must match ", pattern)
      }
      ## Before calling ggplot_build, we do some error checking for
      ## some animint extensions.
      for(L in p$layers){
        ## This code assumes that the layer has the complete aesthetic
        ## mapping and data. TODO: Do we need to copy any global
        ## values to this layer?
        is.ss <- is.showSelected(names(L$mapping))
        is.cs <- names(L$mapping) == "clickSelects"
        update.vars <- L$mapping[is.ss | is.cs]
        has.var <- update.vars %in% names(L$data)
        if(!all(has.var)){
          print(update.vars[!has.var])
          stop("data does not have interactive variables")
        }
        has.cs <- any(is.cs)
        has.href <- "href" %in% names(L$mapping)
        if(has.cs && has.href){
          stop("aes(clickSelects) can not be used with aes(href)")
        }
      }
      meta$plot <- p
      meta$plot.name <- list.name
      parsePlot(meta) # calls ggplot_build.
    }else if(is.list(p)){ ## for options.
      meta[[list.name]] <- p
    }else{
      stop("list items must be ggplots or option lists, problem: ", list.name)
    }
  }
  
  ## Go through options and add to the list.
  for(v.name in names(meta$duration)){
    for(g.name in meta$selectors[[v.name]]$update){
      meta$geoms[[g.name]]$duration <-
        list(ms=meta$duration[[v.name]],
             selector=v.name)
    }
  }
  ## Set plot sizes.
  for(d in c("width","height")){
    size <- meta[[d]]
    if(is.list(size)){
      warning("option ", d, " is deprecated, ",
              "use ggplot()+theme_animint(", d,
              "=", size[[1]],
              ") instead")
      if(is.null(names(size))){ #use this size for all plots.
        for(plot.name in names(meta$plots)){
          meta$plots[[plot.name]]$options[[d]] <- size[[1]]
        }
      }else{ #use the size specified for the named plot.
        for(plot.name in names(size)){
          if(plot.name %in% names(meta$plots)){
            meta$plots[[plot.name]]$options[[d]] <- size[[plot.name]]
          }else{
            stop("no ggplot named ", plot.name)
          }
        }
      }
    }
  }

  ## These geoms need to be updated when the time.var is animated, so
  ## let's make a list of all possible values to cycle through, from
  ## all the values used in those geoms.
  if("time" %in% ls(meta)){
    geom.names <- meta$selectors[[time.var]]$update
    anim.values <- lapply(meta$geoms, "[[", "timeValues")
    anim.not.null <- anim.values[!sapply(anim.values, is.null)]
    meta$time$sequence <- if(all(sapply(anim.not.null, is.numeric))){
      as.character(sort(unique(unlist(anim.not.null))))
    }else if(all(sapply(anim.not.null, is.factor))){
      levs <- levels(anim.not.null[[1]])
      if(any(sapply(anim.not.null, function(f)levels(f)!=levs))){
        print(sapply(anim.not.null, levels))
        stop("all time factors must have same levels")
      }
      levs
    }else{
      stop("time variables must be all numeric or all factor")
    }
    meta$selectors[[time.var]]$selected <- meta$time$sequence[[1]]
  }
  ## The first selection:
  for(selector.name in names(meta$first)){
    first <- as.character(meta$first[[selector.name]])
    stopifnot(length(first) == 1)
    meta$selectors[[selector.name]]$selected <- first
  }

  ## Finally, copy html/js/json files to out.dir.
  src.dir <- system.file("htmljs",package="animint")
  to.copy <- Sys.glob(file.path(src.dir, "*"))
  if(file.exists(paste0(out.dir, "styles.css"))){
    to.copy <- to.copy[!grepl("styles.css", to.copy, fixed=TRUE)]
  }
  file.copy(to.copy, out.dir, overwrite=TRUE, recursive=TRUE)
  export.names <-
    c("geoms", "time", "duration", "selectors", "plots", "title")
  export.data <- list()
  for(export.name in export.names){
    if(export.name %in% ls(meta)){
      export.data[[export.name]] <- meta[[export.name]]
    }
  }
  json <- RJSONIO::toJSON(export.data)
  cat(json, file = file.path(out.dir, json.file))
  if (open.browser) {
    message('opening a web browser with a file:// URL; ',
            'if the web page is blank, try running
install.packages("servr")
servr::httd("', out.dir, '")')
      browseURL(sprintf("%s/index.html", out.dir))
  }
  invisible(meta)
  ### An invisible copy of the R list that was exported to JSON.
}


#' Check if character is an RGB hexadecimal color value
#' @param x character 
#' @return True/False value
#' @export 
is.rgb <- function(x){
  grepl("NULL", x) | (grepl("#", x) & nchar(x)==7)
}

#' Convert R colors to RGB hexadecimal color values
#' @param x character
#' @return hexadecimal color value (if is.na(x), return "none" for compatibility with JavaScript)
#' @export
toRGB <- function(x){
  sapply(x, function(i) if(!is.na(i)) rgb(t(col2rgb(as.character(i))), maxColorValue=255) else "none")
} 

#' Function to get legend information from ggplot
#' @param plistextra output from ggplot2::ggplot_build(p)
#' @return list containing information for each legend
#' @export
getLegendList <- function(plistextra){
  plot <- plistextra$plot
  scales <- plot$scales
  layers <- plot$layers
  default_mapping <- plot$mapping
  theme <- ggplot2:::plot_theme(plot)
  position <- theme$legend.position
  # by default, guide boxes are vertically aligned
  theme$legend.box <- if(is.null(theme$legend.box)) "vertical" else theme$legend.box
  
  # size of key (also used for bar in colorbar guide)
  theme$legend.key.width <- if(is.null(theme$legend.key.width)) theme$legend.key.size
  theme$legend.key.height <- if(is.null(theme$legend.key.height)) theme$legend.key.size
  # by default, direction of each guide depends on the position of the guide.
  theme$legend.direction <- if(is.null(theme$legend.direction)){
    if (length(position) == 1 && position %in% c("top", "bottom", "left", "right"))
      switch(position[1], top =, bottom = "horizontal", left =, right = "vertical")
    else
      "vertical"
  }
  # justification of legend boxes
  theme$legend.box.just <-
    if(is.null(theme$legend.box.just)) {
      if (length(position) == 1 && position %in% c("top", "bottom", "left", "right"))
        switch(position, bottom =, top = c("center", "top"), left =, right = c("left", "top"))
      else
        c("center", "center")
    } 
  
  position <- theme$legend.position
  # locate guide argument in scale_*, and use that for a default.
  # Note, however, that guides(colour = ...) has precendence! See https://gist.github.com/cpsievert/ece28830a6c992b29ab6
  guides.args <- list()
  for(aes.name in c("colour", "fill")){
    aes.loc <- which(scales$find(aes.name))
    guide.type <- if (length(aes.loc) == 1){
      scales$scales[[aes.loc]][["guide"]]
    }else{
      "legend"
    }
    if(guide.type=="colourbar")guide.type <- "legend"
    guides.args[[aes.name]] <- guide.type
  }
  guides.result <- do.call(ggplot2::guides, guides.args)
  guides <- plyr::defaults(plot$guides, guides.result)
  labels <- plot$labels
  gdefs <- ggplot2:::guides_train(scales = scales, theme = theme, guides = guides, labels = labels)
  if (length(gdefs) != 0) {
    gdefs <- ggplot2:::guides_merge(gdefs)
    gdefs <- ggplot2:::guides_geom(gdefs, layers, default_mapping)
  } else (ggplot2:::zeroGrob())
  names(gdefs) <- sapply(gdefs, function(i) i$title)
  lapply(gdefs, getLegend)
}

#' Function to get legend information for each scale
#' @param mb single entry from ggplot2:::guides_merge() list of legend data
#' @return list of legend information, NULL if guide=FALSE.
getLegend <- function(mb){
  guidetype <- mb$name
  ## The main idea of legends:
  
  ## 1. Here in getLegend I export the legend entries as a list of
  ## rows that can be used in a data() bind in D3.

  ## 2. In add_legend in the JS code I create a <table> for every
  ## legend, and then I bind the legend entries to <tr>, <td>, and
  ## <svg> elements.
  geoms <- sapply(mb$geoms, function(i) i$geom$objname)
  cleanData <- function(data, key, geom, params) {
    nd <- nrow(data)
    nk <- nrow(key)
    if (nd == 0) return(data.frame()); # if no rows, return an empty df.
    if ("guide" %in% names(params)) {
      if (params[["guide"]] == "none") return(data.frame()); # if no guide, return an empty df
    } 
    if (nd != nk) warning("key and data have different number of rows")
    if (!".label" %in% names(key)) return(data.frame()); # if there are no labels, return an empty df.
    data$`.label` <- key$`.label`
    data <- data[, which(colSums(!is.na(data)) > 0)] # remove cols that are entirely na
    if("colour" %in% names(data)) data[["colour"]] <- toRGB(data[["colour"]]) # color hex values
    if("fill" %in% names(data)) data[["fill"]] <- toRGB(data[["fill"]]) # fill hex values
    names(data) <- paste0(geom, names(data))# aesthetics by geom
    names(data) <- gsub(paste0(geom, "."), "", names(data), fixed=TRUE) # label isn't geom-specific
    data
  }
  dataframes <- lapply(mb$geoms, function(i) cleanData(i$data, mb$key, i$geom$objname, i$params))
  dataframes <- dataframes[which(sapply(dataframes, nrow)>0)]
  # Check to make sure datframes is non-empty. If it is empty, return NULL.
  if(length(dataframes)>0) {
    data <- merge_recurse(dataframes)
  } else return(NULL)
  data <- lapply(nrow(data):1, function(i) as.list(data[i,]))
  if(guidetype=="none"){
    NULL
  } else{
    list(guide = guidetype, 
         geoms = geoms, 
         title = mb$title, 
         entries = data)
  }
}

#' Function to merge a list of data frames (from the reshape package)
#' @param dfs list of data frames
#' @param ... other arguments to merge
#' @return data frame of merged lists
merge_recurse = function (dfs, ...) 
{
  if (length(dfs) == 1) {
    dfs[[1]]
  }
  else if (length(dfs) == 2) {
    merge(dfs[[1]], dfs[[2]], all.x = TRUE, sort = FALSE, ...)
  }
  else {
    merge(dfs[[1]], Recall(dfs[-1]), all.x = TRUE, sort = FALSE, 
          ...)
  }
}
